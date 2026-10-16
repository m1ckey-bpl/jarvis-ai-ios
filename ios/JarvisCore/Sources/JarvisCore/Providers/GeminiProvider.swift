import Foundation

/// Google AI Studio (Gemini) provider.
///
/// Uses the REST `generateContent` / `streamGenerateContent` endpoints. The key is
/// supplied as a query parameter because that is the documented mechanism for the
/// Gemini API; it is never logged (the redactor scrubs Google key shapes).
public final class GeminiProvider: LLMProvider {
    public let entry: ProviderCatalogEntry
    public let apiKey: String
    private let transport: HTTPTransport
    private let retry: RetryPolicy

    public init(entry: ProviderCatalogEntry, apiKey: String, transport: HTTPTransport = URLSessionTransport(),
                retry: RetryPolicy = .default) {
        self.entry = entry; self.apiKey = apiKey; self.transport = transport; self.retry = retry
    }

    public var id: String { entry.id }
    public var displayName: String { entry.displayName }
    public var defaultModel: String { entry.defaultModel }
    public var availableModels: [String] { entry.models }
    public var setupHint: String { entry.keyInstructions }
    public var documentationURL: URL? { URL(string: entry.signupURL) }

    public func state() async -> CapabilityState {
        apiKey.isEmpty
            ? .requiresConfiguration(detail: "Add your Google AI Studio API key in Settings ▸ AI Providers.")
            : .ready
    }

    private func makeRequest(_ request: ChatRequest, streaming: Bool) throws -> HTTPRequestSpec {
        let model = request.model ?? defaultModel
        let method = streaming ? "streamGenerateContent" : "generateContent"
        let suffix = streaming ? "?alt=sse&key=\(apiKey)" : "?key=\(apiKey)"
        guard let url = URL(string: "\(entry.baseURL)/models/\(model):\(method)\(suffix)") else {
            throw JarvisError.providerNotConfigured
        }

        var contents: [JSONValue] = []
        var systemText: String?
        for message in request.messages {
            switch message.role {
            case .system:
                systemText = (systemText.map { $0 + "\n" } ?? "") + message.content
            case .user:
                contents.append(.obj(("role", .string("user")), ("parts", .array([.obj(("text", .string(message.content)))]))))
            case .assistant:
                var parts: [JSONValue] = []
                if !message.content.isEmpty { parts.append(.obj(("text", .string(message.content)))) }
                for call in message.toolCalls {
                    parts.append(.obj(("functionCall", .obj(
                        ("name", .string(call.name)),
                        ("args", call.arguments)
                    ))))
                }
                contents.append(.obj(("role", .string("model")), ("parts", .array(parts))))
            case .tool:
                contents.append(.obj(("role", .string("user")), ("parts", .array([
                    .obj(("functionResponse", .obj(
                        ("name", .string(message.content.isEmpty ? "tool" : "tool")),
                        ("response", .obj(("result", .string(message.content))))
                    )))
                ]))))
            }
        }

        var body: [String: JSONValue] = [
            "contents": .array(contents),
            "generationConfig": .obj(("temperature", .double(request.temperature)))
        ]
        if let systemText { body["systemInstruction"] = .obj(("parts", .array([.obj(("text", .string(systemText)))]))) }
        if let max = request.maxOutputTokens {
            body["generationConfig"] = .obj(("temperature", .double(request.temperature)),
                                            ("maxOutputTokens", .int(max)))
        }
        if !request.tools.isEmpty {
            let declarations = request.tools.map { tool -> JSONValue in
                .obj(("name", .string(tool.name)),
                     ("description", .string(tool.summary)),
                     ("parameters", tool.providerSchema["function"]?["parameters"] ?? .obj(("type", .string("object")))))
            }
            body["tools"] = .array([.obj(("functionDeclarations", .array(declarations)))])
        }

        var headers = ["Content-Type": "application/json"]
        if streaming { headers["Accept"] = "text/event-stream" }
        return HTTPRequestSpec(url: url, method: "POST", headers: headers,
                               body: try JSONEncoder.jarvis.encode(JSONValue.object(body)),
                               timeout: 90, label: "\(entry.id)/\(method)")
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let spec = try makeRequest(request, streaming: false)
        let payload = try await retry.run { try await transport.send(spec) }
        guard (200..<300).contains(payload.statusCode) else {
            throw URLSessionTransport.mapStatus(payload.statusCode, body: payload.text, headers: payload.headers)
        }
        let json = try payload.json()
        guard let candidate = json["candidates"]?.arrayValue?.first else {
            throw JarvisError.providerBadResponse("Gemini returned no candidates (possibly a safety block)")
        }
        var text = ""
        var calls: [ToolCallRequest] = []
        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
            if let t = part["text"]?.stringValue { text += t }
            if let call = part["functionCall"], let name = call["name"]?.stringValue {
                calls.append(ToolCallRequest(name: name, arguments: call["args"] ?? .object([:])))
            }
        }
        return ChatResponse(text: text, toolCalls: calls,
                            finishReason: candidate["finishReason"]?.stringValue,
                            promptTokens: json["usageMetadata"]?["promptTokenCount"]?.intValue,
                            completionTokens: json["usageMetadata"]?["candidatesTokenCount"]?.intValue,
                            model: request.model ?? defaultModel)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    let spec = try self.makeRequest(request, streaming: true)
                    var parser = SSEParser()
                    var text = ""
                    var calls: [ToolCallRequest] = []
                    var finishReason: String?
                    var promptTokens: Int?
                    var completionTokens: Int?
                    let model = request.model ?? self.defaultModel

                    continuation.yield(.started(model: model))

                    func process(_ event: ServerSentEvent) {
                        guard let delta = ChatStreamDecoder.decodeGemini(event.data) else { return }
                        if !delta.text.isEmpty { text += delta.text; continuation.yield(.textDelta(delta.text)) }
                        if let name = delta.toolCallName {
                            continuation.yield(.toolCallStarted(name: name))
                            calls.append(ToolCallRequest(name: name,
                                                         arguments: (try? JSONDecoder.jarvis.decode(JSONValue.self, from: Data((delta.toolCallArguments ?? "{}").utf8))) ?? .object([:])))
                        }
                        if let value = delta.promptTokens { promptTokens = value }
                        if let value = delta.completionTokens { completionTokens = value }
                        if delta.finished { finishReason = delta.finishReason }
                    }

                    for try await line in self.transport.stream(spec) {
                        if Task.isCancelled { throw JarvisError.cancelled }
                        if let event = parser.consume(line: line) { process(event) }
                    }
                    if let tail = parser.flush() { process(tail) }
                    continuation.yield(.completed(ChatResponse(text: text, toolCalls: calls, finishReason: finishReason,
                                                               promptTokens: promptTokens, completionTokens: completionTokens,
                                                               model: model)))
                    continuation.finish()
                } catch let error as JarvisError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: JarvisError.cancelled)
                } catch {
                    continuation.finish(throwing: JarvisError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
