import Foundation

/// The single source of truth the orb and status rail render from.
/// Every case corresponds to something that is genuinely happening.
public enum AssistantState: Equatable, Sendable {
    case idle
    case listening
    case thinking(detail: String?)
    case speaking
    case executing(tool: String, detail: String)
    case awaitingConfirmation(tool: String)
    case failed(message: String)

    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .executing: return "Working"
        case .awaitingConfirmation: return "Waiting for you"
        case .failed: return "Needs attention"
        }
    }

    public var detail: String? {
        switch self {
        case .thinking(let detail): return detail
        case .executing(_, let detail): return detail
        case .awaitingConfirmation(let tool): return "Approve \(tool)?"
        case .failed(let message): return message
        default: return nil
        }
    }

    /// Drives the orb's animation character (intensity, colour family, motion).
    public var animationProfile: OrbAnimationProfile {
        switch self {
        case .idle: return OrbAnimationProfile(amplitude: 0.25, speed: 0.2, accent: .ice)
        case .listening: return OrbAnimationProfile(amplitude: 0.85, speed: 0.9, accent: .cyan)
        case .thinking: return OrbAnimationProfile(amplitude: 0.5, speed: 0.6, accent: .ice)
        case .speaking: return OrbAnimationProfile(amplitude: 0.75, speed: 0.7, accent: .silver)
        case .executing: return OrbAnimationProfile(amplitude: 0.6, speed: 0.5, accent: .cyan)
        case .awaitingConfirmation: return OrbAnimationProfile(amplitude: 0.4, speed: 0.3, accent: .amber)
        case .failed: return OrbAnimationProfile(amplitude: 0.3, speed: 0.25, accent: .rose)
        }
    }
}

public struct OrbAnimationProfile: Equatable, Sendable {
    public var amplitude: Double
    public var speed: Double
    public var accent: Accent

    public enum Accent: String, Sendable {
        case ice, cyan, silver, amber, rose
    }
}
