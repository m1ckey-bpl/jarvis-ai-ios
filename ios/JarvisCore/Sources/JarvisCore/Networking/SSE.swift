import Foundation

/// One parsed Server-Sent Event.
public struct ServerSentEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event; self.data = data; self.id = id
    }
}

/// Incremental SSE parser driven by the raw lines produced by `HTTPTransport.stream`.
/// Written as an explicit state machine so it is unit-testable without networking.
public struct SSEParser {
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastID: String?

    public init() {}

    /// Flushes a pending event at end-of-stream. Some servers omit the final
    /// blank line, and a dropped final event would silently truncate a response.
    public mutating func flush() -> ServerSentEvent? {
        guard !dataLines.isEmpty else { eventName = nil; return nil }
        let event = ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastID)
        eventName = nil
        dataLines = []
        return event
    }

    /// Feeds one line; returns a complete event when a blank line terminates a block.
    public mutating func consume(line: String) -> ServerSentEvent? {
        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if trimmed.isEmpty { return flush() }
        if trimmed.hasPrefix(":") { return nil }   // comment / keep-alive
        guard let separator = trimmed.firstIndex(of: ":") else {
            dataLines.append(trimmed)
            return nil
        }
        let field = String(trimmed[trimmed.startIndex..<separator])
        var value = String(trimmed[trimmed.index(after: separator)...])
        if value.hasPrefix(" ") { value = String(value.dropFirst()) }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "id": lastID = value
        case "retry": break
        default: break
        }
        return nil
    }
}

/// Extracts the OpenAI-compatible streaming delta and completion signal.
public enum ChatStreamDecoder {
    public struct Delta: Equatable, Sendable {
        public var text: String
        public var toolCallID: String?
        public var toolCallName: String?
        public var toolCallArguments: String?
        public var finished: Bool
        public var finishReason: String?
        public var promptTokens: Int?
        public var completionTokens: Int?
    }

    /// Decodes one SSE data payload from a `/chat/completions` stream.
    public static func decodeOpenAI(_ data: String) -> Delta? {
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            return Delta(text: "", finished: true, finishReason: "stop")
        }
        guard let json = try? JSONDecoder.jarvis.decode(JSONValue.self, from: Data(data.utf8)) else { return nil }
        if let error = json["error"]?["message"]?.stringValue {
            JarvisLog.shared.warn("provider", "stream error payload: \(error)")
            return nil
        }
        guard let choice = json["choices"]?.arrayValue?.first else { return nil }
        let delta = choice["delta"]
        let text = delta?["content"]?.stringValue ?? ""
        let toolCall = delta?["tool_calls"]?.arrayValue?.first
        let toolID = toolCall?["id"]?.stringValue
        let toolName = toolCall?["function"]?["name"]?.stringValue
        let toolArgs = toolCall?["function"]?["arguments"]?.stringValue
        let finish = choice["finish_reason"]?.stringValue
        let usage = json["usage"]
        return Delta(
            text: text,
            toolCallID: toolID,
            toolCallName: toolName,
            toolCallArguments: toolArgs,
            finished: finish != nil,
            finishReason: finish,
            promptTokens: usage?["prompt_tokens"]?.intValue,
            completionTokens: usage?["completion_tokens"]?.intValue
        )
    }

    /// Decodes one SSE payload from Gemini's `streamGenerateContent?alt=sse`.
    public static func decodeGemini(_ data: String) -> Delta? {
        guard let json = try? JSONDecoder.jarvis.decode(JSONValue.self, from: Data(data.utf8)) else { return nil }
        guard let candidate = json["candidates"]?.arrayValue?.first else { return nil }
        let parts = candidate["content"]?["parts"]?.arrayValue ?? []
        var text = ""
        var toolName: String?
        var toolArgs: String?
        for part in parts {
            if let t = part["text"]?.stringValue { text += t }
            if let call = part["functionCall"] {
                toolName = call["name"]?.stringValue
                toolArgs = call["args"]?.jsonString
            }
        }
        let finish = candidate["finishReason"]?.stringValue
        let usage = json["usageMetadata"]
        return Delta(text: text, toolCallName: toolName, toolCallArguments: toolArgs,
                     finished: finish != nil, finishReason: finish,
                     promptTokens: usage?["promptTokenCount"]?.intValue,
                     completionTokens: usage?["candidatesTokenCount"]?.intValue)
    }
}
