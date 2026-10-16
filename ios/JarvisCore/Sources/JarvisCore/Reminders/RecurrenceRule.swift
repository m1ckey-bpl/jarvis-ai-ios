import Foundation

/// A recurrence description limited to what the product actually supports.
///
/// Scope (D9): DAILY / WEEKLY / MONTHLY / YEARLY, with INTERVAL, BYDAY for weekly
/// rules, and COUNT/UNTIL bounds. Anything else is rejected explicitly so a
/// reminder is never silently scheduled at the wrong time.
public struct RecurrenceRule: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily, weekly, monthly, yearly
    }

    public enum Weekday: Int, Codable, CaseIterable, Sendable {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

        public init?(name: String) {
            switch name.lowercased() {
            case "sun", "sunday": self = .sunday
            case "mon", "monday": self = .monday
            case "tue", "tues", "tuesday": self = .tuesday
            case "wed", "wednesday": self = .wednesday
            case "thu", "thur", "thurs", "thursday": self = .thursday
            case "fri", "friday": self = .friday
            case "sat", "saturday": self = .saturday
            default: return nil
            }
        }

        public var name: String {
            switch self {
            case .sunday: return "Sunday"; case .monday: return "Monday"; case .tuesday: return "Tuesday"
            case .wednesday: return "Wednesday"; case .thursday: return "Thursday"
            case .friday: return "Friday"; case .saturday: return "Saturday"
            }
        }
    }

    public var frequency: Frequency
    public var interval: Int
    /// Only meaningful for `.weekly`; empty means "same weekday as the start date".
    public var weekdays: [Weekday]
    public var count: Int?
    public var until: Date?

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Weekday] = [],
                count: Int? = nil, until: Date? = nil) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.count = count.map { max(1, $0) }
        self.until = until
    }

    public static let daily = RecurrenceRule(frequency: .daily)
    public static func weekly(on days: [Weekday], interval: Int = 1) -> RecurrenceRule {
        RecurrenceRule(frequency: .weekly, interval: interval, weekdays: days)
    }
    public static func monthly(interval: Int = 1) -> RecurrenceRule { RecurrenceRule(frequency: .monthly, interval: interval) }
    public static func yearly(interval: Int = 1) -> RecurrenceRule { RecurrenceRule(frequency: .yearly, interval: interval) }

    /// Human description used in confirmations ("every Sunday at 09:00").
    public func describe() -> String {
        let every = interval == 1 ? "Every" : "Every \(interval) "
        switch frequency {
        case .daily: return interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            if weekdays.isEmpty { return "\(every)week".capitalized == "Every Week" ? "Every week" : every + "week" }
            let names = weekdays.sorted { $0.rawValue < $1.rawValue }.map { $0.name }
            return "\(every == "Every" ? "Every" : "Every \(interval) weeks on") \(names.joined(separator: weekdays.count > 2 ? ", " : " and "))".replacingOccurrences(of: "Every  (", with: "Every (")
        case .monthly: return interval == 1 ? "Every month" : "Every \(interval) months"
        case .yearly: return interval == 1 ? "Every year" : "Every \(interval) years"
        }
    }

    /// Next occurrence strictly after `reference` in the given calendar/time zone.
    ///
    /// Implemented with `Calendar` date math so DST transitions and month-length
    /// differences are handled by the platform rather than by arithmetic on seconds.
    public func nextOccurrence(after reference: Date, calendar: Calendar) -> Date? {
        switch frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: interval, to: reference)
        case .weekly:
            let days = weekdays.isEmpty
                ? Weekday(rawValue: calendar.component(.weekday, from: reference)).map { [$0] } ?? []
                : weekdays
            guard !days.isEmpty else { return nil }
            var best: Date?
            // Search the next `interval * 7 + 7` days for the first matching weekday.
            for offset in 1...(7 * interval + 7) {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: reference) else { continue }
                let weekdayComponent = calendar.component(.weekday, from: candidate)
                guard let weekday = Weekday(rawValue: weekdayComponent), days.contains(weekday) else { continue }
                if interval > 1 {
                    // Enforce the interval by requiring whole weeks between occurrences.
                    let weeks = calendar.dateComponents([.weekOfYear], from: reference, to: candidate).weekOfYear ?? 0
                    if weeks % interval != 0 { continue }
                }
                best = candidate
                break
            }
            return best
        case .monthly:
            return calendar.date(byAdding: .month, value: interval, to: reference)
        case .yearly:
            return calendar.date(byAdding: .year, value: interval, to: reference)
        }
    }

    /// All occurrences up to `limit` — used by the UI to preview a schedule.
    public func occurrences(startingAt start: Date, limit: Int = 5, calendar: Calendar) -> [Date] {
        var results: [Date] = []
        var cursor = start
        var produced = 0
        while results.count < limit && produced < limit + 8 {
            produced += 1
            guard let next = nextOccurrence(after: cursor, calendar: calendar) else { break }
            if let until, next > until { break }
            if let count, produced > count { break }
            results.append(next)
            cursor = next
        }
        return results
    }
}
