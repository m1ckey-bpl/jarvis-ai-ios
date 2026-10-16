import Foundation

/// The honest state of any user-facing capability.
///
/// The product rule (R14/R16) is that a feature must *always* be able to state
/// why it cannot do something, rather than silently degrading or faking success.
public enum CapabilityState: Equatable, Sendable {
    case ready
    case requiresConfiguration(detail: String)
    case requiresPermission(detail: String)
    case requiresBackend(detail: String)
    case unavailable(reason: String)
    case exhausted(detail: String)

    public var isUsable: Bool { self == .ready }

    public var label: String {
        switch self {
        case .ready: return "Ready"
        case .requiresConfiguration: return "Setup needed"
        case .requiresPermission: return "Permission needed"
        case .requiresBackend: return "Backend needed"
        case .unavailable: return "Unavailable"
        case .exhausted: return "Quota reached"
        }
    }

    public var explanation: String {
        switch self {
        case .ready: return "Available now."
        case .requiresConfiguration(let detail): return detail
        case .requiresPermission(let detail): return detail
        case .requiresBackend(let detail): return detail
        case .unavailable(let reason): return reason
        case .exhausted(let detail): return detail
        }
    }
}

/// A named capability plus its current state and what to do about it.
public struct Capability: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    /// Whether this capability needs the optional backend to function at all.
    public var requiresBackend: Bool
    public var state: CapabilityState

    public init(id: String, name: String, summary: String, requiresBackend: Bool = false, state: CapabilityState) {
        self.id = id; self.name = name; self.summary = summary
        self.requiresBackend = requiresBackend; self.state = state
    }
}

/// Central registry that the UI reads to render "Connected Services",
/// onboarding and recovery screens. Providers/keys/permissions register facts here.
public final class CapabilityRegistry: @unchecked Sendable {
    private var storage: [String: Capability] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ capability: Capability) {
        lock.lock(); defer { lock.unlock() }
        storage[capability.id] = capability
    }

    public func update(id: String, state: CapabilityState) {
        lock.lock(); defer { lock.unlock() }
        storage[id]?.state = state
    }

    public func capability(id: String) -> Capability? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    public var all: [Capability] {
        lock.lock(); defer { lock.unlock() }
        return storage.values.sorted { $0.name < $1.name }
    }

    /// Configured-but-unavailable summary used by the "Recovery" screen.
    public var actionable: [Capability] {
        all.filter { !$0.state.isUsable }
    }
}

/// Canonical capability identifiers.
public enum CapabilityID {
    public static let assistant = "assistant.core"
    public static let memory = "memory.runtime"
    public static let reminders = "reminders.local"
    public static let voiceInput = "voice.input"
    public static let voiceOutput = "voice.output"
    public static let notifications = "notifications.local"
    public static let micPermission = "permission.microphone"
    public static let speechPermission = "permission.speech"
    public static let notificationPermission = "permission.notifications"
    public static let calendarPermission = "permission.calendar"
    public static let gmail = "integration.gmail"
    public static let github = "integration.github"
    public static let instagram = "integration.instagram"
    public static let whatsapp = "integration.whatsapp"
    public static let appleCalendar = "integration.appleCalendar"
    public static let appleReminders = "integration.appleReminders"
    public static let webSearch = "tool.webSearch"
    public static let codingAgent = "agent.coding"
    public static let backend = "backend.companion"
}
