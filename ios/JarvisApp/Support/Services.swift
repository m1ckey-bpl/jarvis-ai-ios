import Foundation
import UserNotifications
import EventKit
import os

/// Bridges the engine logger to the unified system log (visible in Console.app,
/// never containing secrets because `JarvisLog` redacts before writing).
public struct OSLogSink: LogSink {
    private let logger = Logger(subsystem: "ai.jarvis.app", category: "jarvis")
    public init() {}
    public func write(level: LogLevel, category: String, message: String) {
        switch level {
        case .debug: logger.debug("[\(category, privacy: .public)] \(message, privacy: .private)")
        case .info: logger.info("[\(category, privacy: .public)] \(message, privacy: .private)")
        case .warning: logger.warning("[\(category, privacy: .public)] \(message, privacy: .private)")
        case .error: logger.error("[\(category, privacy: .public)] \(message, privacy: .private)")
        }
    }
}

/// Local notification scheduling for reminders.
///
/// Apple's notification centre is the only reliable way to alert the user while the
/// app is not running (no background execution is assumed). Every method reports
/// the real outcome — a reminder is never "scheduled" without a confirmed request.
public final class NotificationScheduler: ReminderScheduler {

    private let center = UNUserNotificationCenter.current()

    public init() {}

    public func currentAuthorizationState() async -> CapabilityState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .ready
        case .denied:
            return .requiresPermission(detail: "Notifications are turned off for JARVIS. Enable them in iOS Settings ▸ Notifications ▸ JARVIS.")
        case .notDetermined:
            return .requiresPermission(detail: "JARVIS needs notification permission to deliver reminders.")
        @unknown default:
            return .requiresPermission(detail: "Notification permission state is unknown.")
        }
    }

    public func requestAuthorization() async -> CapabilityState {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            JarvisLog.shared.warn("notifications", "authorization request failed: \(error.localizedDescription)")
        }
        return await currentAuthorizationState()
    }

    public func schedule(reminder: Reminder, fireDate: Date) async throws -> String {
        let state = await currentAuthorizationState()
        guard state.isUsable else {
            throw JarvisError.unavailable(reason: state.explanation)
        }
        let identifier = reminder.notificationIdentifier ?? "jarvis.reminder.\(reminder.id)"

        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.notes ?? "Reminder from JARVIS"
        content.sound = reminder.priority == .high ? .defaultCritical : .default
        content.interruptionLevel = reminder.priority == .high ? .timeSensitive : .active
        content.userInfo = ["reminderID": reminder.id]

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = reminder.timeZone
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        components.timeZone = reminder.timeZone

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        // Replace any previous request for this reminder.
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        try await center.add(request)
        // `add` throws on failure, so reaching here means the system accepted it.
        return identifier
    }

    public func cancel(identifier: String) async throws {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    public func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map { $0.identifier }
    }
}

/// EventKit bridge for Apple Calendar (and Reminders-style events).
///
/// Requests access only when the user enables the capability, and reports the
/// genuine permission state instead of assuming success.
public final class EventKitCalendarBridge: CalendarBridge {

    private let store = EKEventStore()

    public init() {}

    public func state() async -> CapabilityState {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess: return .ready
        case .writeOnly:
            return .requiresPermission(detail: "JARVIS has write-only calendar access; full access is needed to read your schedule.")
        case .denied:
            return .requiresPermission(detail: "Calendar access was denied. Enable it in iOS Settings ▸ Privacy ▸ Calendars.")
        case .restricted:
            return .unavailable(reason: "Calendar access is restricted on this device.")
        case .notDetermined:
            return .requiresPermission(detail: "Grant calendar access to let JARVIS read and create events.")
        @unknown default:
            return .requiresPermission(detail: "Calendar permission state is unknown.")
        }
    }

    public func requestAccess() async -> CapabilityState {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            JarvisLog.shared.warn("calendar", "access request failed: \(error.localizedDescription)")
        }
        return await state()
    }

    public func upcomingEvents(days: Int) async throws -> [(title: String, start: Date, end: Date, calendar: String, location: String?)] {
        let state = await state()
        guard state.isUsable else { throw JarvisError.unavailable(reason: state.explanation) }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start.addingTimeInterval(86_400 * 7)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { ($0.title ?? "Untitled", $0.startDate, $0.endDate, $0.calendar.title, $0.location) }
    }

    public func createEvent(title: String, start: Date, end: Date, notes: String?, calendarName: String?) async throws -> String {
        let state = await state()
        guard state.isUsable else { throw JarvisError.unavailable(reason: state.explanation) }
        guard end > start else { throw JarvisError.invalidArguments("the event must end after it starts") }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = calendarName.flatMap { name in store.calendars(for: .event).first { $0.title == name } }
            ?? store.defaultCalendarForNewEvents
        guard event.calendar != nil else {
            throw JarvisError.unavailable(reason: "No writable calendar is available on this device.")
        }
        try store.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else {
            throw JarvisError.unexpected("the calendar did not return an identifier for the new event")
        }
        return identifier
    }
}

/// Haptics, centralised so the design system uses them consistently (and so the
/// patterns can be reviewed for accessibility in one place).
public enum Haptics {
    public static func tap() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred()
        #endif
    }

    public static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    public static func warning() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    public static func error() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    public static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}
