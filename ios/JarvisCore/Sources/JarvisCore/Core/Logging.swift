import Foundation

/// Minimal, dependency-free logger with **mandatory redaction**.
///
/// Security rule R15: secrets and private message bodies must never reach logs.
/// `Redactor` is applied to every message before it is emitted.
public struct Redactor: Sendable {
    /// Patterns (regex source) whose matches are replaced with `***`.
    public static let defaultPatterns: [String] = [
        #"(?i)(bearer\s+)[A-Za-z0-9\-\._~\+/]{8,}"#,
        #"(?i)(api[_-]?key\"?\s*[:=]\s*\"?)[A-Za-z0-9\-\._~]{8,}"#,
        #"\bAIza[0-9A-Za-z\-_]{20,}\b"#,          // Google API keys
        #"\bgsk_[A-Za-z0-9]{20,}\b"#,              // Groq keys
        #"\bsk-[A-Za-z0-9\-_]{16,}\b"#,            // OpenAI-style keys
        #"\bsk-or-v1-[A-Za-z0-9]{16,}\b"#,         // OpenRouter keys
        #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,        // GitHub tokens
        #"\bya29\.[A-Za-z0-9\-_\.]{10,}\b"#,       // Google OAuth access tokens
        #"\b\d{1,2}:\d{2}:\d{2}:[0-9]{2}:[0-9]{2}\b"#, // Google refresh token shape
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
    ]

    private let compiled: [NSRegularExpression]

    public init(patterns: [String] = Redactor.defaultPatterns) {
        self.compiled = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    public func redact(_ text: String) -> String {
        var result = text
        for regex in compiled {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1***")
        }
        return result
    }

    /// Truncates long payloads (e.g. email bodies) unless explicitly allowed.
    public func redact(_ text: String, truncateTo limit: Int?) -> String {
        let redacted = redact(text)
        guard let limit, redacted.count > limit else { return redacted }
        return String(redacted.prefix(limit)) + "…[truncated \(redacted.count - limit) chars]"
    }
}

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warning, error
    public static func < (l: LogLevel, r: LogLevel) -> Bool { l.rawValue < r.rawValue }
}

public protocol LogSink: Sendable {
    func write(level: LogLevel, category: String, message: String)
}

/// Console sink. On iOS this bridges to `os.Logger` in the app layer.
public struct ConsoleLogSink: LogSink {
    public init() {}
    public func write(level: LogLevel, category: String, message: String) {
        print("[\(level)] [\(category)] \(message)")
    }
}

/// Collecting sink used by tests to assert on diagnostics.
public final class MemoryLogSink: LogSink, @unchecked Sendable {
    public private(set) var lines: [(level: LogLevel, category: String, message: String)] = []
    private let lock = NSLock()
    public init() {}
    public func write(level: LogLevel, category: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append((level, category, message))
    }
}

public final class JarvisLog: @unchecked Sendable {
    public static let shared = JarvisLog()

    public var minimumLevel: LogLevel = .info
    public var sink: LogSink = ConsoleLogSink()
    public let redactor = Redactor()

    public init() {}

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= minimumLevel else { return }
        sink.write(level: level, category: category, message: redactor.redact(message))
    }

    public func debug(_ c: String, _ m: String) { log(.debug, c, m) }
    public func info(_ c: String, _ m: String) { log(.info, c, m) }
    public func warn(_ c: String, _ m: String) { log(.warning, c, m) }
    public func error(_ c: String, _ m: String) { log(.error, c, m) }
}
