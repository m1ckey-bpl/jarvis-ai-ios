import Foundation

/// Provider for any endpoint implementing the OpenAI Chat Completions API
/// (Groq, OpenRouter, Cerebras, NVIDIA NIM, Ollama, LM Studio, vLLM…).
///
/// Streaming, tool calling, cancellation, bounded retries and explicit error
/// mapping are implemented here so every provider behaves predictably.
public final class OpenAICompatibleProvider: LLMProvider {
    public let entry: ProviderCatalogEntry
    public let apiKey: String
    public let baseURL: String
    private let transport: HTTPTransport
    private let retry: RetryPolicy

    public init(entry: ProviderCatalogEntry, apiKey: String, baseURL: String,
                transport: HTTPTransport = URLSessionTransport(), retry: RetryPolicy = .default) {
        self.entry = entry; self.apiKey = apiKey; self.baseURL = baseURL
        self.transport = transport; self.retry = retry
    }

    public var id: String { entry.id }
    public var displayName: String { entry.displayName }
    public var defaultModel: String { entry.defaultModel }
    public var availableModels: [String] { entry.models }
    public var setupHint: String { entry.keyInstructions }
    public var documentationURL: URL? { URL(string: entry.signupURL) }

    public func state() async -> CapabilityState {
        if entry.requiresKey && apiKey.isEmpty {
            return .requiresConfiguration(detail: "Add your \(entry.displayName) API key in Settings ▸ AI Providers.")
        }
        guard URL(string: baseURL) != nil else {
            return .requiresConfiguration(detail: "The base URL for \(entry.displayName) is not a valid URL.")
        }
        return .ready
    }

    // MARK: Request building

    private func makeRequest(_ request: ChatRequest) throws -> HTTPRequestSpec {
        guard let url = URL(string: baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions") else {
            throw JarvisError.providerNotConfigured
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model ?? defaultModel),
            "messages": .array(request.messages.map(Self.encode(message:))),
            "temperature": .double(request.temperature),
            "stream": .bool(true)
        ]
        if let max = request.maxOutputTokens { body["max_tokens"] = .int(max) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { $0.providerSchema })
            body["tool_choice"] = .string(request.toolChoice.rawValue)
        }
        var headers: [String: String] = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        if !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        if entry.id == "openrouter" {
            // OpenRouter asks for attribution headers; they are not secrets.
            headers["HTTP-Referer"] = "https://github.com/jarvis-ai-ios"
            headers["X-Title"] = "JARVIS iOS"
        }
        return HTTPRequestSpec(url: url, method: "POST", headers: headers,
                               body: try JSONEncoder.jarvis.encode(JSONValue.object(body)),
                               timeout: 90, label: "\(entry.id)/chat.completions")
    }

    static func encode(message: ChatMessage) -> JSONValue {
        var object: [String: JSONValue] = ["role": .string(message.role.rawValue)]
        object["content"] = .string(message.content)
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = .array(message.toolCalls.map { call in
                .obj(("id", .string(call.id)),
                     ("type", .string("function")),
                     ("function", .obj(("name", .string(call.name)),
                                       ("arguments", .string(call.arguments.jsonString)))))
            })
        }
        if let toolCallID = message.toolCallID { object["tool_call_id"] = .string(toolCallID) }
        return .object(object)
    }

    // MARK: Non-streaming

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        var spec = try makeRequest(request)
        spec.headers["Accept"] = "application/json"
        // Non-streaming variant: strip the stream flag.
        if let data = spec.body, var json = try? JSONDecoder.jarvis.decode(JSONValue.self, from: data),
           case .object(var object) = json {
            object["stream"] = .bool(false)
            json = .object(object)
            spec.body = try JSONEncoder.jarvis.encode(json)
        }
        let payload = try await retry.run { try await transport.send(spec) }
        guard (200..<300).contains(payload.statusCode) else {
            throw URLSessionTransport.mapStatus(payload.statusCode, body: payload.text, headers: payload.headers)
        }
        let json = try payload.json()
        guard let choice = json["choices"]?.arrayValue?.first else {
            throw JarvisError.providerBadResponse("missing choices in response")
        }
        let message = choice["message"]
        let calls = Self.decodeToolCalls(message?["tool_calls"]?.arrayValue ?? [])
        return ChatResponse(
            text: message?["content"]?.stringValue ?? "",
            toolCalls: calls,
            finishReason: choice["finish_reason"]?.stringValue,
            promptTokens: json["usage"]?["prompt_tokens"]?.intValue,
            completionTokens: json["usage"]?["completion_tokens"]?.intValue,
            model: json["model"]?.stringValue ?? defaultModel
        )
    }

    static func decodeToolCalls(_ array: [JSONValue]) -> [ToolCallRequest] {
        array.compactMap { element in
            guard let name = element["function"]?["name"]?.stringValue else { return nil }
            let rawArguments = element["function"]?["arguments"]?.stringValue ?? "{}"
            let parsed = (try? JSONDecoder.jarvis.decode(JSONValue.self, from: Data(rawArguments.utf8))) ?? .object([:])
            return ToolCallRequest(id: element["id"]?.stringValue ?? UUID().uuidString,
                                   name: name, arguments: parsed)
        }
    }

    // MARK: Streaming

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    let spec = try self.makeRequest(request)
                    var parser = SSEParser()
                    var text = ""
                    var calls: [ToolCallRequest] = []
                    var currentName: String?
                    var currentArguments = ""
                    var currentID: String?
                    var finishReason: String?
                    var promptTokens: Int?
                    var completionTokens: Int?
                    let model = request.model ?? self.defaultModel

                    /// Applies one SSE event to the accumulated response state.
                    func process(_ event: ServerSentEvent) {
                        guard let delta = ChatStreamDecoder.decodeOpenAI(event.data) else { return }
                        if !delta.text.isEmpty {
                            text += delta.text
                            continuation.yield(.textDelta(delta.text))
                        }
                        if let name = delta.toolCallName {
                            // A new tool call starts; flush the previous one.
                            if let finishedName = currentName {
                                calls.append(ToolCallRequest(
                                    id: currentID ?? UUID().uuidString,
                                    name: finishedName,
                                    arguments: (try? JSONDecoder.jarvis.decode(JSONValue.self, from: Data(currentArguments.utf8))) ?? .object([:])
                                ))
                            }
                            currentName = name
                            currentArguments = ""
                            currentID = delta.toolCallID
                            continuation.yield(.toolCallStarted(name: name))
                        }
                        if let argumentsDelta = delta.toolCallArguments {
                            currentArguments += argumentsDelta
                            if delta.toolCallName == nil { continuation.yield(.toolCallArgumentsDelta(argumentsDelta)) }
                        }
                        if let value = delta.promptTokens { promptTokens = value }
                        if let value = delta.completionTokens { completionTokens = value }
                        if delta.finished { finishReason = delta.finishReason ?? "stop" }
                    }

                    continuation.yield(.started(model: model))

                    var attempts = 0
                    lineLoop: while true {
                        attempts += 1
                        do {
                            for try await line in self.transport.stream(spec) {
                                if Task.isCancelled { throw JarvisError.cancelled }
                                if let event = parser.consume(line: line) { process(event) }
                            }
                            if let tail = parser.flush() { process(tail) }
                            break lineLoop
                        } catch let error as JarvisError where error.isRetryable && attempts < self.retry.maxAttempts {
                            JarvisLog.shared.warn("provider", "stream attempt \(attempts) failed (\(error)); retrying")
                            try await Task.sleep(nanoseconds: UInt64(self.retry.delay(forAttempt: attempts) * 1_000_000_000))
                            parser = SSEParser()
                        }
                    }

                    if let finishedName = currentName {
                        calls.append(ToolCallRequest(
                            id: currentID ?? UUID().uuidString,
                            name: finishedName,
                            arguments: (try? JSONDecoder.jarvis.decode(JSONValue.self, from: Data(currentArguments.utf8))) ?? .object([:])
                        ))
                    }
                    continuation.yield(.completed(ChatResponse(text: text, toolCalls: calls, finishReason: finishReason,
                                                              promptTokens: promptTokens, completionTokens: completionTokens,
                                                              model: model)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: JarvisError.cancelled)
                } catch let error as JarvisError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: JarvisError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
