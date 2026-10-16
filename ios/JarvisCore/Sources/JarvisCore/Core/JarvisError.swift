import Foundation

/// Canonical error taxonomy for the JARVIS engine.
///
/// Every case maps to a *user-actionable* state so that the UI can present an
/// honest explanation (the product must never fake success or hide failures).
public enum JarvisError: Error, Equatable, Sendable {
    /// No inference provider has been configured yet.
    case providerNotConfigured
    /// The user's stored credential was rejected.
    case providerUnauthorized(String)
    /// The provider's free quota / rate limit was hit.
    case providerQuotaExceeded(retryAfterSeconds: Int?)
    /// Provider was reachable but returned an unusable payload.
    case providerBadResponse(String)
    /// Network failure (offline, DNS, TLS, timeout).
    case network(String)
    /// Request exceeded its deadline.
    case timeout(seconds: Double)
    /// The operation was cancelled by the user or superseded.
    case cancelled
    /// Tool/argument validation failed.
    case invalidArguments(String)
    /// Policy forbade executing the tool without explicit user confirmation.
    case confirmationRequired(tool: String, reason: String)
    /// Policy forbade the action outright.
    case policyBlocked(String)
    /// Needed capability (permission, service, hardware) is unavailable.
    case unavailable(reason: String)
    /// Storage-layer failure.
    case storage(String)
    /// Catch-all with a safe, non-sensitive description.
    case unexpected(String)

    /// Short, safe message suitable for display. Never contains secrets.
    public var userMessage: String {
        switch self {
        case .providerNotConfigured:
            return "No AI provider is configured yet. Open Settings ▸ AI Providers to connect a free provider."
        case .providerUnauthorized:
            return "The saved API key was rejected. Re-enter it in Settings ▸ AI Providers."
        case .providerQuotaExceeded(let retry):
            if let retry { return "The provider's free quota is exhausted. Try again in about \(Self.describe(seconds: retry))." }
            return "The provider's free quota is exhausted. Try again later or switch providers in Settings."
        case .providerBadResponse(let detail):
            return "The provider returned an unexpected response. \(detail)"
        case .network(let detail):
            return "Network problem: \(detail)"
        case .timeout(let s):
            return "The request timed out after \(Int(s))s."
        case .cancelled:
            return "Cancelled."
        case .invalidArguments(let detail):
            return "The requested action was rejected: \(detail)"
        case .confirmationRequired(let tool, let reason):
            return "Confirmation required before running \(tool): \(reason)"
        case .policyBlocked(let reason):
            return "That action is blocked by policy: \(reason)"
        case .unavailable(let reason):
            return reason
        case .storage(let detail):
            return "Local storage error: \(detail)"
        case .unexpected(let detail):
            return "Something went wrong: \(detail)"
        }
    }

    /// Whether retrying the identical request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .network, .timeout: return true
        case .providerQuotaExceeded(let retry): return retry == nil || (retry ?? 0) > 0
        default: return false
        }
    }

    private static func describe(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }
}

/// Result of an action the engine attempted on the user's behalf.
///
/// `ToolOutcome` deliberately separates "the engine tried" from "the world
/// changed": only `success` may be reported to the user as an accomplished action.
public enum ActionOutcome: Sendable, Equatable {
    case success(summary: String, details: JSONValue?)
    case needsConfirmation(PendingConfirmation)
    case failed(JarvisError)
    case cancelled
}
