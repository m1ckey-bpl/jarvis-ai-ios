import Foundation

/// Injectable time source — makes reminder/recency logic deterministic in tests.
public protocol Clock: Sendable {
    var now: Date { get }
    var timeZone: TimeZone { get }
}

public struct SystemClock: Clock {
    public let timeZone: TimeZone
    public init(timeZone: TimeZone = .current) { self.timeZone = timeZone }
    public var now: Date { Date() }
}

/// Manual clock for tests and for previewing scheduled behaviour.
public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    public var timeZone: TimeZone

    public init(now: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) {
        self._now = now
        self.timeZone = timeZone
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        _now = date
    }
}

public extension Date {
    var iso8601: String { ISO8601DateFormatter.jarvis.string(from: self) }

    static func fromISO8601(_ s: String) -> Date? { ISO8601DateFormatter.jarvis.date(from: s) }

    /// Human-friendly relative description used in prompts and memory summaries.
    ///
    /// Implemented manually (rather than with `DateComponentsFormatter`) so the
    /// engine behaves identically on Apple platforms and swift-corelibs-foundation.
    func relativeDescription(from reference: Date = Date()) -> String {
        let delta = reference.timeIntervalSince(self)
        let future = delta < 0
        let seconds = abs(delta)
        let text: String
        switch seconds {
        case ..<60: text = "\(Int(seconds)) second\(Int(seconds) == 1 ? "" : "s")"
        case ..<3600: text = "\(Int(seconds / 60)) minute\(Int(seconds / 60) == 1 ? "" : "s")"
        case ..<86_400: text = "\(Int(seconds / 3600)) hour\(Int(seconds / 3600) == 1 ? "" : "s")"
        case ..<604_800: text = "\(Int(seconds / 86_400)) day\(Int(seconds / 86_400) == 1 ? "" : "s")"
        case ..<2_592_000: text = "\(Int(seconds / 604_800)) week\(Int(seconds / 604_800) == 1 ? "" : "s")"
        default: text = "\(Int(seconds / 2_592_000)) month\(Int(seconds / 2_592_000) == 1 ? "" : "s")"
        }
        return future ? "in \(text)" : "\(text) ago"
    }
}

public extension ISO8601DateFormatter {
    static let jarvis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
