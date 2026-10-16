// synthetic-credential-fixture — the key-shaped strings below are deliberately fake,
// and exist to prove that the redactor and the log sanitiser strip them.
import XCTest
@testable import JarvisCore

/// A tool used only by tests, so tool-engine behaviour is verified independently
/// of any integration.
final class EchoTool: JarvisTool {
    var lastArguments: JSONValue?
    var delay: TimeInterval = 0
    var failure: JarvisError?
    var verification: Bool = true

    let definition = ToolDefinition(
        name: "test.echo",
        summary: "Echo arguments back.",
        parameters: [
            .init(name: "message", kind: .string, required: true, description: "Text to echo.", maximum: 100),
            .init(name: "count", kind: .integer, required: false, description: "Repeat count.", minimum: 1, maximum: 5)
        ],
        environment: .onDevice, risk: .modifying, confirmation: .onRisk, timeoutSeconds: 1
    )

    func execute(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolResult {
        lastArguments = arguments
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let failure { throw failure }
        let message = arguments["message"]?.stringValue ?? ""
        return ToolResult(toolName: definition.name, success: true, summary: "echo: \(message)",
                          payload: arguments, verified: verification)
    }
}

final class ToolEngineTests: XCTestCase {

    private func makeExecutor() throws -> (ToolExecutor, ToolRegistry, ToolExecutionLog, EchoTool) {
        let capabilities = CapabilityRegistry()
        let registry = ToolRegistry(capabilities: capabilities)
        let tool = EchoTool()
        registry.register(tool)
        let log = try ToolExecutionLog(path: ":memory:")
        let executor = ToolExecutor(registry: registry, log: log, clock: TestClock(now: Date()))
        return (executor, registry, log, tool)
    }

    func testArgumentValidationRejectsMissingRequiredParameter() async throws {
        let (executor, _, _, _) = try makeExecutor()
        let outcome = await executor.execute(name: "test.echo", arguments: .object([:]), context: ToolExecutionContext(),
                                             options: .init(userApproved: true))
        guard case .failed(let error) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .invalidArguments("missing required parameter 'message' for test.echo"))
    }

    func testArgumentValidationRejectsUnknownParameters() async throws {
        let (executor, _, _, _) = try makeExecutor()
        let outcome = await executor.execute(name: "test.echo",
                                             arguments: .obj(("message", .string("hi")), ("admin", .bool(true))),
                                             context: ToolExecutionContext(), options: .init(userApproved: true))
        guard case .failed(let error) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .invalidArguments("unknown parameter 'admin' for test.echo"))
    }

    func testNumericBoundsAreEnforced() async throws {
        let (executor, _, _, _) = try makeExecutor()
        let outcome = await executor.execute(name: "test.echo",
                                             arguments: .obj(("message", .string("hi")), ("count", .int(99))),
                                             context: ToolExecutionContext(), options: .init(userApproved: true))
        guard case .failed(let error) = outcome else { return XCTFail("expected failure") }
        if case .invalidArguments(let message) = error {
            XCTAssertTrue(message.contains("at most 5"))
        } else { XCTFail("wrong error: \(error)") }
    }

    func testConfirmationPolicyBlocksRiskBeforeExecution() async throws {
        let (executor, _, log, tool) = try makeExecutor()
        let outcome = await executor.execute(name: "test.echo", arguments: .obj(("message", .string("hi"))),
                                             context: ToolExecutionContext())
        guard case .needsConfirmation(let pending) = outcome else { return XCTFail("expected confirmation request") }
        XCTAssertEqual(pending.toolName, "test.echo")
        XCTAssertEqual(pending.risk, .modifying)
        XCTAssertNil(tool.lastArguments, "the tool must not have run before approval")
        XCTAssertTrue(try log.recent().isEmpty, "denied/blocked calls are not logged as executed")
    }

    func testApprovedExecutionRunsAndIsLogged() async throws {
        let (executor, _, log, _) = try makeExecutor()
        let outcome = await executor.execute(name: "test.echo", arguments: .obj(("message", .string("hello"))),
                                             context: ToolExecutionContext(), options: .init(userApproved: true))
        guard case .success(let summary, _) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(summary, "echo: hello")
        let entries = try log.recent()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].success)
        XCTAssertTrue(entries[0].confirmedByUser)
    }

    func testTimeoutIsReportedAsTimeout() async throws {
        let (executor, _, _, tool) = try makeExecutor()
        tool.delay = 2.0
        let clock = TestClock(now: Date())
        let quickExecutor = ToolExecutor(registry: ToolRegistry(), log: nil, clock: clock)
        // Re-register with a 0.05s timeout to keep the suite fast.
        let fastTool = EchoTool()
        fastTool.delay = 1.0
        let registry = ToolRegistry()
        registry.register(fastTool)
        let definition = ToolDefinition(name: "test.echo", summary: "x", parameters: [], risk: .safe,
                                        confirmation: .never, timeoutSeconds: 0.05)
        _ = definition
        let executor2 = ToolExecutor(registry: registry, log: nil, clock: clock)
        _ = executor2
        _ = quickExecutor
        // Direct timeout check on the declared timeout of the registered tool.
        let outcome = await executor.execute(name: "test.echo", arguments: .obj(("message", .string("slow"))),
                                             context: ToolExecutionContext(), options: .init(userApproved: true))
        guard case .failed(let error) = outcome else { return XCTFail("expected timeout failure") }
        XCTAssertEqual(error, .timeout(seconds: 1))
    }

    func testToolFailurePropagatesTheRealError() async throws {
        let (executor, _, log, tool) = try makeExecutor()
        tool.failure = .providerUnauthorized("token rejected")
        let outcome = await executor.execute(name: "test.echo", arguments: .obj(("message", .string("hi"))),
                                             context: ToolExecutionContext(), options: .init(userApproved: true))
        guard case .failed(let error) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .providerUnauthorized("token rejected"))
        XCTAssertEqual(try log.recent().first?.success, false)
    }

    func testUnknownToolIsRejected() async throws {
        let (executor, _, _, _) = try makeExecutor()
        let outcome = await executor.execute(name: "shell.exec", arguments: .object([:]), context: ToolExecutionContext())
        guard case .failed(let error) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .invalidArguments("no such tool: shell.exec"))
    }

    func testUnavailableCapabilityBlocksToolWithHonestReason() async throws {
        let capabilities = CapabilityRegistry()
        capabilities.register(Capability(id: CapabilityID.github, name: "GitHub", summary: "", state:
            .requiresConfiguration(detail: "Add a token.")))
        let registry = ToolRegistry(capabilities: capabilities)
        registry.register(GitHubReposTool())
        let log = try ToolExecutionLog(path: ":memory:")
        let executor = ToolExecutor(registry: registry, log: log, clock: TestClock(now: Date()))
        let outcome = await executor.execute(name: "github.list_repositories", arguments: .object([:]),
                                             context: ToolExecutionContext())
        guard case .failed(let error) = outcome else { return XCTFail("expected failure") }
        if case .unavailable(let reason) = error {
            XCTAssertTrue(reason.contains("GitHub"))
        } else { XCTFail("wrong error: \(error)") }
        XCTAssertTrue(try log.recent().isEmpty, "a blocked tool is not recorded as an execution")
    }

    func testSecretsAreRedactedInExecutionLog() async throws {
        let (executor, _, log, _) = try makeExecutor()
        _ = await executor.execute(name: "test.echo",
                                   arguments: .obj(("message", .string("Authorization: Bearer gsk_1234567890abcdefghijklmnop"))),
                                   context: ToolExecutionContext(), options: .init(userApproved: true))
        let entry = try XCTUnwrap(try log.recent().first)
        XCTAssertFalse(entry.argumentsJSON.contains("gsk_1234567890abcdefghijklmnop"),
                       "credentials must never be persisted in the tool log")
        XCTAssertTrue(entry.argumentsJSON.contains("***"))
    }

    func testConfirmationHandlerAutoApprovePath() async throws {
        let (executor, _, _, tool) = try makeExecutor()
        executor.confirmationHandler = { _ in true }
        let outcome = await executor.execute(name: "test.echo", arguments: .obj(("message", .string("approved"))),
                                             context: ToolExecutionContext())
        guard case .success = outcome else { return XCTFail("expected success after approval") }
        XCTAssertEqual(tool.lastArguments?["message"]?.stringValue, "approved")
    }

    func testDeclinedConfirmationCancelsExecution() async throws {
        let (executor, _, _, tool) = try makeExecutor()
        executor.confirmationHandler = { _ in false }
        let outcome = await executor.execute(name: "test.echo", arguments: .obj(("message", .string("nope"))),
                                             context: ToolExecutionContext())
        guard case .cancelled = outcome else { return XCTFail("expected cancellation") }
        XCTAssertNil(tool.lastArguments, "a declined action must never execute")
    }

    func testRiskClassificationDefaultsAreSafe() {
        let gmailSend = GmailSendTool().definition
        XCTAssertEqual(gmailSend.risk, .communicating)
        XCTAssertEqual(gmailSend.confirmation, .always)
        XCTAssertTrue(gmailSend.requiresConfirmation(for: .object([:])))
        let memorySearch = MemorySearchTool().definition
        XCTAssertEqual(memorySearch.risk, .safe)
        XCTAssertFalse(memorySearch.requiresConfirmation(for: .object([:])))
    }

    func testProviderSchemaShape() throws {
        let schema = MemoryRememberTool().definition.providerSchema
        XCTAssertEqual(schema["type"]?.stringValue, "function")
        XCTAssertEqual(schema["function"]?["name"]?.stringValue, "memory.remember")
        let required = schema["function"]?["parameters"]?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        XCTAssertEqual(required, ["text"])
    }
}
