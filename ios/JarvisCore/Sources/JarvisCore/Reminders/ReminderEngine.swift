import Foundation

public struct Reminder: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var notes: String?
    /// First fire time (absolute, stored in UTC).
    public var dueAt: Date
    /// The time zone the user created it in — recurrence is evaluated in this zone
    /// so "every Sunday 9am" stays 9am local even if they travel.
    public var timeZoneIdentifier: String
    public var recurrence: RecurrenceRule?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var cancelledAt: Date?
    /// Identifier handed to the OS notification centre so it can be updated/cancelled.
    public var notificationIdentifier: String?
    public var priority: Priority
    public var source: Source
    public var lastError: String?

    public enum Priority: String, Codable, Sendable { case low, normal, high }
    public enum Source: String, Codable, Sendable { case user, assistant }

    public init(id: String = UUID().uuidString, title: String, notes: String? = nil, dueAt: Date,
                timeZoneIdentifier: String, recurrence: RecurrenceRule? = nil, createdAt: Date = Date(),
                updatedAt: Date? = nil, completedAt: Date? = nil, cancelledAt: Date? = nil,
                notificationIdentifier: String? = nil, priority: Priority = .normal,
                source: Source = .user, lastError: String? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.dueAt = dueAt
        self.timeZoneIdentifier = timeZoneIdentifier; self.recurrence = recurrence
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt; self.cancelledAt = cancelledAt
        self.notificationIdentifier = notificationIdentifier; self.priority = priority
        self.source = source; self.lastError = lastError
    }

    public var isOpen: Bool { completedAt == nil && cancelledAt == nil }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Next fire time at or after `date` (handles recurrence).
    public func nextFireDate(after date: Date) -> Date? {
        guard let recurrence else { return dueAt > date ? dueAt : nil }
        if dueAt > date { return dueAt }
        return recurrence.nextOccurrence(after: max(dueAt, date), calendar: calendar)
    }

    public func describe() -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let base = formatter.string(from: dueAt)
        guard let recurrence else { return base }
        return "\(base) · \(recurrence.describe())"
    }
}

/// How a reminder is actually delivered. The iOS implementation wraps
/// `UNUserNotificationCenter`; tests use the in-memory recorder.
///
/// A scheduler must **report failures** — a reminder is only "scheduled" once the
/// scheduler confirms it (spec §9: never report success without confirmation).
public protocol ReminderScheduler: AnyObject {
    /// Requests authorization if needed. Returns the resulting state.
    func requestAuthorization() async -> CapabilityState
    func currentAuthorizationState() async -> CapabilityState
    /// Schedules (or replaces) a notification; returns the identifier on success.
    func schedule(reminder: Reminder, fireDate: Date) async throws -> String
    func cancel(identifier: String) async throws
    func pendingIdentifiers() async -> [String]
}

/// Records scheduling intent without delivering notifications. Used in unit tests
/// and on platforms without a notification centre. It never claims delivery.
public final class RecordingReminderScheduler: ReminderScheduler {
    public private(set) var scheduled: [(identifier: String, reminderID: String, fireDate: Date)] = []
    public private(set) var cancelled: [String] = []
    public var authorizationToGrant: CapabilityState = .ready
    public var failureForNextSchedule: JarvisError?

    public init() {}

    public func requestAuthorization() async -> CapabilityState { authorizationToGrant }
    public func currentAuthorizationState() async -> CapabilityState { authorizationToGrant }

    public func schedule(reminder: Reminder, fireDate: Date) async throws -> String {
        if let failure = failureForNextSchedule { failureForNextSchedule = nil; throw failure }
        let identifier = reminder.notificationIdentifier ?? "jarvis.reminder.\(reminder.id)"
        scheduled.removeAll { $0.identifier == identifier }
        scheduled.append((identifier, reminder.id, fireDate))
        return identifier
    }

    public func cancel(identifier: String) async throws {
        cancelled.append(identifier)
        scheduled.removeAll { $0.identifier == identifier }
    }

    public func pendingIdentifiers() async -> [String] { scheduled.map { $0.identifier } }

    /// Clears recorded scheduling state (used to simulate the OS dropping notifications).
    public func reset() { scheduled.removeAll(); cancelled.removeAll() }
}

/// Persistence for reminders.
public final class ReminderStore {
    private let db: SQLiteDatabase

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try Migrator.migrate(db, migrations: ReminderStore.migrations)
    }

    public static let migrations: [Migration] = [
        Migration(version: 1, name: "reminders schema", statements: [
            """
            CREATE TABLE IF NOT EXISTS reminders (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                notes TEXT,
                due_at REAL NOT NULL,
                tz TEXT NOT NULL,
                recurrence TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL,
                cancelled_at REAL,
                notification_id TEXT,
                priority TEXT NOT NULL,
                source TEXT NOT NULL,
                last_error TEXT
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(due_at);",
            "CREATE INDEX IF NOT EXISTS idx_reminders_open ON reminders(cancelled_at, completed_at);"
        ])
    ]

    public func upsert(_ reminder: Reminder) throws {
        let recurrenceJSON = reminder.recurrence.flatMap { try? JSONEncoder.jarvis.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.run("""
            INSERT INTO reminders (id, title, notes, due_at, tz, recurrence, created_at, updated_at,
                                   completed_at, cancelled_at, notification_id, priority, source, last_error)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title, notes=excluded.notes, due_at=excluded.due_at, tz=excluded.tz,
                recurrence=excluded.recurrence, updated_at=excluded.updated_at,
                completed_at=excluded.completed_at, cancelled_at=excluded.cancelled_at,
                notification_id=excluded.notification_id, priority=excluded.priority,
                source=excluded.source, last_error=excluded.last_error
            """, [
                .text(reminder.id), .text(reminder.title),
                reminder.notes.map { SQLValue.text($0) } ?? .null,
                .double(reminder.dueAt.timeIntervalSince1970), .text(reminder.timeZoneIdentifier),
                recurrenceJSON.map { SQLValue.text($0) } ?? .null,
                .double(reminder.createdAt.timeIntervalSince1970), .double(reminder.updatedAt.timeIntervalSince1970),
                reminder.completedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                reminder.cancelledAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                reminder.notificationIdentifier.map { SQLValue.text($0) } ?? .null,
                .text(reminder.priority.rawValue), .text(reminder.source.rawValue),
                reminder.lastError.map { SQLValue.text($0) } ?? .null
            ])
    }

    public func reminder(id: String) throws -> Reminder? {
        try db.query("SELECT * FROM reminders WHERE id = ?;", [.text(id)]).first.flatMap(Self.decode)
    }

    public func all(includeClosed: Bool = false) throws -> [Reminder] {
        let sql = includeClosed
            ? "SELECT * FROM reminders ORDER BY due_at ASC;"
            : "SELECT * FROM reminders WHERE completed_at IS NULL AND cancelled_at IS NULL ORDER BY due_at ASC;"
        return try db.query(sql).compactMap(Self.decode)
    }

    public func due(between start: Date, and end: Date, includeClosed: Bool = false) throws -> [Reminder] {
        var rows = try db.query("SELECT * FROM reminders WHERE due_at >= ? AND due_at < ? ORDER BY due_at ASC;",
                                [.double(start.timeIntervalSince1970), .double(end.timeIntervalSince1970)])
        rows += try db.query("SELECT * FROM reminders WHERE recurrence IS NOT NULL AND cancelled_at IS NULL;")
        var decoded = rows.compactMap(Self.decode)
        var unique: [String: Reminder] = [:]
        for reminder in decoded {
            guard let next = reminder.nextFireDate(after: start.addingTimeInterval(-1)) else { continue }
            guard next >= start, next < end else { continue }
            unique[reminder.id] = reminder
        }
        if includeClosed { decoded = try all(includeClosed: true) } else {
            decoded = Array(unique.values)
        }
        return decoded.sorted { ($0.nextFireDate(after: start) ?? $0.dueAt) < ($1.nextFireDate(after: start) ?? $1.dueAt) }
    }

    public func delete(id: String) throws { try db.run("DELETE FROM reminders WHERE id = ?;", [.text(id)]) }
    public func deleteAll() throws { try db.run("DELETE FROM reminders;") }

    private static func decode(_ row: [String: SQLValue]) -> Reminder? {
        guard let id = row["id"]?.string, let title = row["title"]?.string,
              let due = row["due_at"]?.double, let tz = row["tz"]?.string,
              let created = row["created_at"]?.double, let updated = row["updated_at"]?.double,
              let priorityRaw = row["priority"]?.string, let priority = Reminder.Priority(rawValue: priorityRaw),
              let sourceRaw = row["source"]?.string, let source = Reminder.Source(rawValue: sourceRaw) else { return nil }
        let recurrence = row["recurrence"]?.string
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder.jarvis.decode(RecurrenceRule.self, from: $0) }
        return Reminder(
            id: id, title: title, notes: row["notes"]?.string,
            dueAt: Date(timeIntervalSince1970: due), timeZoneIdentifier: tz, recurrence: recurrence,
            createdAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: updated),
            completedAt: row["completed_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            cancelledAt: row["cancelled_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            notificationIdentifier: row["notification_id"]?.string,
            priority: priority, source: source, lastError: row["last_error"]?.string
        )
    }
}

/// The reminder domain service: parsing, scheduling, editing, cancellation.
public final class ReminderEngine {
    private let store: ReminderStore
    private let scheduler: ReminderScheduler
    private let clock: Clock

    public init(store: ReminderStore, scheduler: ReminderScheduler, clock: Clock = SystemClock()) {
        self.store = store; self.scheduler = scheduler; self.clock = clock
    }

    public struct SchedulingReceipt: Equatable, Sendable {
        public var reminder: Reminder
        /// True only when the OS scheduler confirmed the notification.
        public var notificationConfirmed: Bool
        public var note: String
    }

    // MARK: Creation

    /// Creates a reminder from a natural-language request.
    /// Returns a `JarvisError.invalidArguments` when the time cannot be understood,
    /// so the assistant asks a clarifying question rather than guessing.
    public func create(fromNaturalLanguage text: String, title: String? = nil,
                       timeZone: TimeZone? = nil) async throws -> SchedulingReceipt {
        let zone = timeZone ?? clock.timeZone
        let parser = DateTimeParser(timeZone: zone)
        guard let parsed = parser.parse(text, now: clock.now) else {
            throw JarvisError.invalidArguments("I could not find a clear date or time in “\(text)”. Tell me when — for example “tomorrow at 9am” or “every Sunday at 6pm”.")
        }
        let cleanTitle = title ?? Self.extractTitle(from: text, matched: parsed.matchedText) ?? "Reminder"
        return try await schedule(
            title: cleanTitle,
            dueAt: parsed.date,
            recurrence: parsed.recurrence,
            notes: parsed.hadExplicitTime ? nil : "Time defaulted to 09:00 — edit the reminder to change it.",
            timeZone: zone,
            source: .assistant
        )
    }

    /// Creates a reminder with explicit values (used by the UI and tool engine).
    public func schedule(title: String, dueAt: Date, recurrence: RecurrenceRule? = nil,
                         notes: String? = nil, priority: Reminder.Priority = .normal,
                         timeZone: TimeZone? = nil, source: Reminder.Source = .user) async throws -> SchedulingReceipt {
        let zone = timeZone ?? clock.timeZone
        guard dueAt > clock.now.addingTimeInterval(-1) || recurrence != nil else {
            throw JarvisError.invalidArguments("that time is already in the past")
        }
        var reminder = Reminder(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                notes: notes, dueAt: dueAt,
                                timeZoneIdentifier: zone.identifier, recurrence: recurrence,
                                createdAt: clock.now, priority: priority, source: source)
        if reminder.title.isEmpty { reminder.title = "Reminder" }

        let fireDate = reminder.nextFireDate(after: clock.now) ?? dueAt
        var confirmed = false
        var note = ""
        do {
            let identifier = try await scheduler.schedule(reminder: reminder, fireDate: fireDate)
            reminder.notificationIdentifier = identifier
            confirmed = true
            note = "Notification scheduled for \(fireDate.iso8601)."
        } catch let error as JarvisError {
            reminder.lastError = error.userMessage
            note = "Saved on this device, but the notification could not be scheduled: \(error.userMessage)"
        } catch {
            reminder.lastError = error.localizedDescription
            note = "Saved on this device, but the notification could not be scheduled."
        }

        try store.upsert(reminder)
        return SchedulingReceipt(reminder: reminder, notificationConfirmed: confirmed, note: note)
    }

    // MARK: Editing

    public func update(id: String, title: String? = nil, dueAt: Date? = nil,
                       recurrence: RecurrenceRule?? = nil, notes: String?? = nil) async throws -> SchedulingReceipt {
        guard var reminder = try store.reminder(id: id) else {
            throw JarvisError.invalidArguments("no reminder with id \(id)")
        }
        if let title { reminder.title = title }
        if let dueAt { reminder.dueAt = dueAt }
        if let recurrence { reminder.recurrence = recurrence }
        if let notes { reminder.notes = notes }
        reminder.updatedAt = clock.now

        if let identifier = reminder.notificationIdentifier {
            try? await scheduler.cancel(identifier: identifier)
        }
        let fireDate = reminder.nextFireDate(after: clock.now) ?? reminder.dueAt
        var confirmed = false
        var note = ""
        do {
            reminder.notificationIdentifier = try await scheduler.schedule(reminder: reminder, fireDate: fireDate)
            confirmed = true
            note = "Rescheduled for \(fireDate.iso8601)."
        } catch let error as JarvisError {
            reminder.lastError = error.userMessage
            note = "Updated locally; notification could not be scheduled: \(error.userMessage)"
        }
        try store.upsert(reminder)
        return SchedulingReceipt(reminder: reminder, notificationConfirmed: confirmed, note: note)
    }

    @discardableResult
    public func complete(id: String) async throws -> Reminder {
        guard var reminder = try store.reminder(id: id) else {
            throw JarvisError.invalidArguments("no reminder with id \(id)")
        }
        reminder.completedAt = clock.now
        reminder.updatedAt = clock.now
        if let identifier = reminder.notificationIdentifier { try? await scheduler.cancel(identifier: identifier) }

        // A recurring reminder rolls forward automatically.
        if let recurrence = reminder.recurrence,
           let next = recurrence.nextOccurrence(after: clock.now, calendar: reminder.calendar) {
            var rolled = Reminder(title: reminder.title, notes: reminder.notes, dueAt: next,
                                  timeZoneIdentifier: reminder.timeZoneIdentifier, recurrence: recurrence,
                                  createdAt: clock.now, priority: reminder.priority, source: reminder.source)
            rolled.notificationIdentifier = try? await scheduler.schedule(reminder: rolled, fireDate: next)
            try store.upsert(rolled)
        }
        try store.upsert(reminder)
        return reminder
    }

    /// Cancels a reminder. `match` supports "cancel my 6pm reminder".
    public func cancel(matching match: String) async throws -> [Reminder] {
        let candidates = try store.all()
        let matched = Self.match(candidates, query: match, now: clock.now)
        for var reminder in matched {
            reminder.cancelledAt = clock.now
            reminder.updatedAt = clock.now
            if let identifier = reminder.notificationIdentifier { try? await scheduler.cancel(identifier: identifier) }
            try store.upsert(reminder)
        }
        return matched
    }

    public func cancel(id: String) async throws {
        guard var reminder = try store.reminder(id: id) else {
            throw JarvisError.invalidArguments("no reminder with id \(id)")
        }
        reminder.cancelledAt = clock.now
        reminder.updatedAt = clock.now
        if let identifier = reminder.notificationIdentifier { try? await scheduler.cancel(identifier: identifier) }
        try store.upsert(reminder)
    }

    public func delete(id: String) async throws {
        if let reminder = try store.reminder(id: id), let identifier = reminder.notificationIdentifier {
            try? await scheduler.cancel(identifier: identifier)
        }
        try store.delete(id: id)
    }

    // MARK: Reading

    public func open(limit: Int = 100) throws -> [Reminder] { try Array(store.all().prefix(limit)) }

    public func today() throws -> [Reminder] { try window(dayOffset: 0) }
    public func tomorrow() throws -> [Reminder] { try window(dayOffset: 1) }

    private func window(dayOffset: Int) throws -> [Reminder] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = clock.timeZone
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: dayOffset, to: clock.now) ?? clock.now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return try store.due(between: start, and: end)
    }

    public func upcoming(limit: Int = 10) throws -> [Reminder] {
        try store.all().sorted { ($0.nextFireDate(after: clock.now) ?? $0.dueAt) < ($1.nextFireDate(after: clock.now) ?? $1.dueAt) }
            .prefix(limit).map { $0 }
    }

    public func authorizationState() async -> CapabilityState { await scheduler.currentAuthorizationState() }

    public func requestAuthorization() async -> CapabilityState { await scheduler.requestAuthorization() }

    /// Reconciles stored reminders with what the OS actually has pending — surfaces
    /// drift (e.g. after a restore) instead of assuming everything is fine.
    public func reconcile() async -> [Reminder] {
        let pending = Set(await scheduler.pendingIdentifiers())
        var drifted: [Reminder] = []
        for reminder in (try? store.all()) ?? [] {
            guard let identifier = reminder.notificationIdentifier else {
                if reminder.isOpen, !pending.contains("jarvis.reminder.\(reminder.id)") { drifted.append(reminder) }
                continue
            }
            if !pending.contains(identifier) { drifted.append(reminder) }
        }
        return drifted
    }

    // MARK: Helpers

    static func match(_ reminders: [Reminder], query: String, now: Date) -> [Reminder] {
        // Match "cancel my 6pm reminder" style queries against time and title.
        let lower = query.lowercased()
        let parser = DateTimeParser(timeZone: TimeZone.current)
        let parsedTime = parser.parse(lower, now: now)
        let tokens = TextNormalizer.tokenList(lower)
        var matches: [Reminder] = []
        for reminder in reminders where reminder.isOpen {
            if let parsedTime, abs(reminder.dueAt.timeIntervalSince(parsedTime.date)) < 3600 {
                matches.append(reminder); continue
            }
            let titleTokens = Set(TextNormalizer.tokenList(reminder.title))
            if !titleTokens.isEmpty, !titleTokens.intersection(tokens).isEmpty { matches.append(reminder) }
        }
        if matches.isEmpty, let parsedTime {
            matches = reminders.filter { $0.isOpen && abs($0.dueAt.timeIntervalSince(parsedTime.date)) < 6 * 3600 }
        }
        return matches
    }

    /// Strips the time expression from the request to obtain a usable title.
    static func extractTitle(from input: String, matched: String) -> String? {
        var removable = Set(matched.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        removable.formUnion(fillerWords)
        let kept = input.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?")) }
            .filter { token in
                guard !token.isEmpty else { return false }
                let lower = token.lowercased()
                if fillerWords.contains(lower) { return false }
                if removable.contains(lower) { return false }
                if Int(lower.filter { $0.isNumber }) != nil { return false }
                return true
            }
        let cleaned = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }

    /// Words that carry no meaning in a reminder title.
    private static let fillerWords: Set<String> = [
        "remind", "reminds", "reminder", "me", "set", "a", "an", "the", "to", "for", "please",
        "at", "on", "by", "in", "about", "that", "i", "should", "add", "create", "make", "sure"
    ]

}
