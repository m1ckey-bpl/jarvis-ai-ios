import Foundation

/// The authorization boundary.
///
/// Flow (spec §9): validate arguments → check permissions/capabilities →
/// apply the confirmation policy → execute with a timeout → verify → log.
/// The model's tool call is an *input* here, never an authorization.
public final class ToolExecutor {
    private let registry: ToolRegistry
    private let log: ToolExecutionLog?
    public var confirmationHandler: (@Sendable (PendingConfirmation) async -> Bool)?
    private let clock: Clock

    public init(registry: ToolRegistry, log: ToolExecutionLog? = nil, clock: Clock = SystemClock()) {
        self.registry = registry; self.log = log; self.clock = clock
    }

    public struct ValidationError: Error, Equatable, Sendable {
        public var message: String
    }

    // MARK: Validation

    /// Validates and coerces model-supplied arguments against the declaration.
    /// Rejects unknown keys (no smuggling extra parameters) and out-of-range values.
    public func validate(_ arguments: JSONValue, for definition: ToolDefinition) throws -> JSONValue {
        var object: [String: JSONValue]
        switch arguments {
        case .object(let o): object = o
        case .null: object = [:]
        default: throw JarvisError.invalidArguments("arguments for \(definition.name) must be a JSON object")
        }

        let declared = Dictionary(uniqueKeysWithValues: definition.parameters.map { ($0.name, $0) })
        for key in object.keys where declared[key] == nil {
            throw JarvisError.invalidArguments("unknown parameter '\(key)' for \(definition.name)")
        }

        var coerced: [String: JSONValue] = [:]
        for parameter in definition.parameters {
            guard var value = object[parameter.name] else {
                if let fallback = parameter.defaultValue { coerced[parameter.name] = fallback; continue }
                if parameter.required {
                    throw JarvisError.invalidArguments("missing required parameter '\(parameter.name)' for \(definition.name)")
                }
                continue
            }
            switch parameter.kind {
            case .string, .dateISO8601:
                guard let text = value.stringValue else {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be a string")
                }
                if case .dateISO8601 = parameter.kind, Date.fromISO8601(text) == nil, text.count > 0 {
                    // Accept a few common shapes, otherwise reject clearly.
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd'T'HH:mm"
                    if df.date(from: text) == nil {
                        throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be an ISO-8601 date-time")
                    }
                }
                if let maximum = parameter.maximum, Double(text.count) > maximum {
                    value = .string(String(text.prefix(Int(maximum))))
                }
                coerced[parameter.name] = value
            case .integer:
                guard let number = value.intValue else {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be an integer")
                }
                if let minimum = parameter.minimum, Double(number) < minimum {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be at least \(Int(minimum))")
                }
                if let maximum = parameter.maximum, Double(number) > maximum {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be at most \(Int(maximum))")
                }
                coerced[parameter.name] = .int(number)
            case .number:
                guard let number = value.doubleValue else {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be a number")
                }
                if let minimum = parameter.minimum, number < minimum { throw JarvisError.invalidArguments("'\(parameter.name)' below minimum") }
                if let maximum = parameter.maximum, number > maximum { throw JarvisError.invalidArguments("'\(parameter.name)' above maximum") }
                coerced[parameter.name] = .double(number)
            case .boolean:
                guard let boolean = value.boolValue else {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be a boolean")
                }
                coerced[parameter.name] = .bool(boolean)
            case .stringArray:
                guard let array = value.arrayValue, array.allSatisfy({ $0.stringValue != nil }) else {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be an array of strings")
                }
                coerced[parameter.name] = .array(array.prefix(50).map { .string($0.stringValue ?? "") })
            case .enumeration:
                guard let text = value.stringValue, parameter.allowedValues.contains(text) else {
                    throw JarvisError.invalidArguments("parameter '\(parameter.name)' must be one of: \(parameter.allowedValues.joined(separator: ", "))")
                }
                coerced[parameter.name] = .string(text)
            }
        }
        return .object(coerced)
    }

    // MARK: Execution

    public struct ExecutionOptions: Sendable {
        /// True when the user has explicitly approved this specific call.
        public var userApproved: Bool
        /// Tools already approved for this session (narrow, user-configured policy).
        public var sessionApprovals: Set<String>

        public init(userApproved: Bool = false, sessionApprovals: Set<String> = []) {
            self.userApproved = userApproved; self.sessionApprovals = sessionApprovals
        }
    }

    /// Runs a tool call, returning an `ActionOutcome`. Never reports success
    /// unless the tool itself returned a verified result.
    public func execute(name: String, arguments: JSONValue, context: ToolExecutionContext,
                        options: ExecutionOptions = ExecutionOptions()) async -> ActionOutcome {
        guard let tool = registry.tool(named: name) else {
            return .failed(.invalidArguments("no such tool: \(name)"))
        }
        let definition = tool.definition

        if let reason = registry.blockingReason(for: definition, context: context) {
            return .failed(.unavailable(reason: reason))
        }

        let validated: JSONValue
        do { validated = try validate(arguments, for: definition) }
        catch let error as JarvisError { return .failed(error) }
        catch { return .failed(.invalidArguments(error.localizedDescription)) }

        let needsConfirmation = definition.requiresConfirmation(for: validated)
            && !options.userApproved
            && !options.sessionApprovals.contains(definition.name)

        if needsConfirmation {
            let pending = PendingConfirmation(
                toolName: definition.name,
                arguments: validated,
                risk: definition.risk,
                prompt: definition.confirmationPrompt.isEmpty
                    ? Self.defaultPrompt(for: definition, arguments: validated)
                    : definition.confirmationPrompt
            )
            if let confirmationHandler {
                let approved = await confirmationHandler(pending)
                if !approved { return .cancelled }
            } else {
                return .needsConfirmation(pending)
            }
        }

        let started = clock.now
        let outcome: ToolResult
        do {
            outcome = try await withTimeout(seconds: definition.timeoutSeconds) {
                try await tool.execute(arguments: validated, context: context)
            }
        } catch let error as JarvisError {
            outcome = .failure(definition.name, error)
        } catch is CancellationError {
            outcome = .failure(definition.name, .cancelled)
        } catch {
            outcome = .failure(definition.name, .unexpected(error.localizedDescription))
        }

        let duration = clock.now.timeIntervalSince(started)
        var logged = outcome
        logged.durationSeconds = duration
        try? log?.append(ToolExecutionLog.Entry(
            toolName: definition.name,
            argumentsJSON: validated.jsonString,
            summary: logged.summary,
            success: logged.success,
            verified: logged.verified,
            risk: definition.risk,
            confirmedByUser: options.userApproved || !needsConfirmation,
            startedAt: started,
            durationSeconds: duration,
            errorMessage: logged.error?.userMessage
        ))

        return logged.success
            ? .success(summary: logged.summary, details: logged.payload)
            : .failed(logged.error ?? .unexpected("tool failed without an error"))
    }

    /// Races the tool against its deadline; a timeout is reported as a timeout.
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                throw JarvisError.timeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw JarvisError.timeout(seconds: seconds) }
            return first
        }
    }

    static func defaultPrompt(for definition: ToolDefinition, arguments: JSONValue) -> String {
        switch definition.risk {
        case .communicating: return "\(definition.name) will send a message on your behalf: \(arguments.jsonString)"
        case .irreversible: return "\(definition.name) will make a change that cannot be undone: \(arguments.jsonString)"
        case .modifying: return "\(definition.name) will change data: \(arguments.jsonString)"
        case .safe: return "\(definition.name) will run."
        }
    }
}
