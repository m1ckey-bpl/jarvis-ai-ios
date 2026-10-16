import Foundation

/// Bridge between the tool engine (which must block for an answer) and the UI
/// (which asks the human). Keeps the security-critical decision explicit and testable.
///
/// Two failure modes are handled deliberately:
///  * a decision that arrives **before** the request registers (UI reacts faster than
///    the engine schedules) — buffered instead of being lost;
///  * a decision that **never** arrives — after `defaultTimeout` the action is
///    refused, because "no answer" must never mean "go ahead".
public final class ConfirmationBroker: @unchecked Sendable {
    private struct Waiter {
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var waiters: [String: Waiter] = [:]
    private var earlyDecisions: [String: Bool] = [:]
    private let lock = NSLock()

    /// How long an unanswered confirmation waits before defaulting to "declined".
    public var defaultTimeout: TimeInterval = 300
    /// Called whenever a new confirmation appears (UI hook / test hook).
    public var onRequest: (@Sendable (PendingConfirmation) -> Void)?

    public init() {}

    /// Awaits the user's decision for `confirmation`.
    public func request(_ confirmation: PendingConfirmation, timeout: TimeInterval? = nil) async -> Bool {
        onRequest?(confirmation)

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if let early = earlyDecisions.removeValue(forKey: confirmation.id) {
                lock.unlock()
                continuation.resume(returning: early)
                return
            }
            waiters[confirmation.id] = Waiter(continuation: continuation)
            lock.unlock()

            // Safety net: an unanswered prompt is a "no".
            let deadline = timeout ?? defaultTimeout
            if deadline > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self] in
                    self?.resolve(id: confirmation.id, approved: false, reason: "timed out waiting for the user")
                }
            }
        }
        return decision
    }

    /// Resolves a pending confirmation. Safe to call before or after `request`.
    public func resolve(id: String, approved: Bool, reason: String? = nil) {
        if let reason { JarvisLog.shared.info("confirm", "confirmation \(id) \(approved ? "approved" : "declined"): \(reason)") }
        lock.lock()
        if let waiter = waiters.removeValue(forKey: id) {
            lock.unlock()
            waiter.continuation.resume(returning: approved)
            return
        }
        // Nobody is waiting yet (or anymore): remember the decision so the engine
        // can still observe it instead of hanging.
        earlyDecisions[id] = approved
        if earlyDecisions.count > 32 { earlyDecisions.removeAll() }
        lock.unlock()
    }

    public var pendingIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(waiters.keys)
    }

    /// Declines everything still waiting (used when a turn is cancelled or the app backgrounds).
    public func declineAll(reason: String) {
        lock.lock()
        let ids = Array(waiters.keys)
        lock.unlock()
        for id in ids { resolve(id: id, approved: false, reason: reason) }
    }
}
