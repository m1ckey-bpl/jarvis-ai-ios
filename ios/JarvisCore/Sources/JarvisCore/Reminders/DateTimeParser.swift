import Foundation

/// Deterministic natural-language date/time parser for reminders.
///
/// Supported (and tested) phrases:
///   "in 20 minutes", "in 2 hours", "in 3 days", "in 1 week"
///   "tomorrow at 9am", "tomorrow 9:30", "today at 18:00", "tonight", "this evening"
///   "next monday at 8", "monday 7pm", "on 24/12 at 10:00", "december 5 at 7pm"
///   "every day at 7am", "every sunday at 9", "every weekday at 8:30", "every 2 weeks"
///
/// Anything it cannot parse confidently returns `nil` so the assistant can ask a
/// clarifying question instead of scheduling the wrong thing.
public struct DateTimeParser {
    public struct Result: Equatable, Sendable {
        public var date: Date
        public var recurrence: RecurrenceRule?
        public var hadExplicitTime: Bool
        public var matchedText: String
    }

    private let calendar: Calendar

    public init(timeZone: TimeZone, locale: Locale = Locale(identifier: "en_US_POSIX")) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        self.calendar = calendar
    }

    // MARK: Public entry point

    public func parse(_ input: String, now: Date) -> Result? {
        let text = " " + input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + " "
        var recurrence: RecurrenceRule?
        var matched: [String] = []

        // ---- Recurrence ----
        if let weekly = matchWeekly(in: text) {
            recurrence = weekly.rule
            matched.append(weekly.text)
        } else if let interval = matchEveryInterval(in: text) {
            recurrence = interval.rule
            matched.append(interval.text)
        }

        // ---- Absolute clock time ----
        var components = DateComponents()
        var hadTime = false
        if let clock = matchClock(in: text) {
            components.hour = clock.hour
            components.minute = clock.minute
            hadTime = true
            matched.append(clock.text)
        } else if text.contains("noon") {
            components.hour = 12; components.minute = 0; hadTime = true; matched.append("noon")
        } else if let partOfDay = matchPartOfDay(in: text) {
            components.hour = partOfDay.hour; components.minute = partOfDay.minute
            hadTime = true
            matched.append(partOfDay.text)
        }

        // ---- Relative offsets ----
        if let offset = matchRelative(in: text) {
            guard let base = calendar.date(byAdding: offset.component, value: offset.value, to: now) else { return nil }
            let candidate = hadTime ? combine(date: base, time: components) : base
            matched.append(offset.text)
            return Result(date: candidate, recurrence: recurrence, hadExplicitTime: hadTime || offset.unitIsPrecise,
                          matchedText: matched.joined(separator: " "))
        }

        // ---- Day anchors ----
        var day: Date?
        if text.contains(" tomorrow ") || text.contains(" tmrw ") {
            day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            matched.append("tomorrow")
        } else if text.contains(" today ") {
            day = calendar.startOfDay(for: now); matched.append("today")
        } else if let weekday = matchWeekday(in: text) {
            day = nextDate(for: weekday.weekday, after: now, includingToday: false)
            matched.append(weekday.text)
        } else if let absolute = matchAbsoluteDate(in: text, now: now) {
            day = absolute.date
            matched.append(absolute.text)
        } else if text.contains(" tonight ") || text.contains(" this evening ") {
            day = calendar.startOfDay(for: now)
            if !hadTime { components.hour = 20; components.minute = 0; hadTime = true }
            matched.append("tonight")
        }

        guard let baseDay = day ?? (hadTime ? calendar.startOfDay(for: now) : nil) else {
            // Recurrence-only request ("every sunday") with no time: default 09:00.
            if let recurrence {
                let weekdays = recurrence.weekdays.isEmpty
                    ? [RecurrenceRule.Weekday(rawValue: calendar.component(.weekday, from: now))!]
                    : recurrence.weekdays
                let anchor = DateComponents(hour: 9, minute: 0)
                let first = weekdays.compactMap { nextDate(for: $0, after: now, includingToday: false) }.min() ?? now
                let date = calendar.date(bySettingHour: anchor.hour!, minute: anchor.minute!, second: 0, of: first) ?? first
                return Result(date: date, recurrence: recurrence, hadExplicitTime: false, matchedText: matched.joined(separator: " "))
            }
            return nil
        }

        var finalComponents = components
        if !hadTime {
            // A day without a clock time: 09:00 is the documented default, and the
            // confirmation text states it explicitly.
            finalComponents.hour = 9
            finalComponents.minute = 0
        }
        var candidate = combine(date: baseDay, time: finalComponents)

        // "monday at 7" meant 7 AM only if it is already past? No: keep 07:00 as
        // stated, but if the resulting moment is in the past and there is no
        // recurrence, roll forward sensibly for relative day anchors.
        if recurrence == nil, candidate <= now {
            if day == nil, hadTime { // time-of-day only, already passed today → tomorrow
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            } else if let recurrence = recurrence {
                candidate = recurrence.nextOccurrence(after: candidate, calendar: calendar) ?? candidate
            }
        }

        // Recurring rules always start at the next future occurrence.
        if let recurrence, candidate <= now {
            candidate = recurrence.nextOccurrence(after: candidate, calendar: calendar) ?? candidate
        }

        return Result(date: candidate, recurrence: recurrence, hadExplicitTime: hadTime, matchedText: matched.joined(separator: " "))
    }

    // MARK: Matchers

    /// Patterns carry the index of their meridiem group, so "6pm" (no minutes)
    /// parses as 18:00 rather than 06:00.
    private static let clockPatterns: [(pattern: String, hourGroup: Int, minuteGroup: Int?, meridiemGroup: Int?)] = [
        (#"\b(\d{1,2}):(\d{2})\s*(am|pm)?\b"#, 1, 2, 3),
        (#"\b(\d{1,2})\.(\d{2})\s*(am|pm)?\b"#, 1, 2, 3),
        (#"\b(\d{1,2})\s*(am|pm)\b"#, 1, nil, 2),
        (#"\bat\s+(\d{1,2})\b"#, 1, nil, nil)
    ]

    private func matchClock(in text: String) -> (hour: Int, minute: Int, text: String)? {
        for pattern in Self.clockPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern.pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { continue }
            func group(_ index: Int?) -> String? {
                guard let index, index < match.numberOfRanges, let r = Range(match.range(at: index), in: text) else { return nil }
                return String(text[r])
            }
            guard let hourText = group(pattern.hourGroup), var hour = Int(hourText) else { continue }
            let minute = group(pattern.minuteGroup).flatMap { Int($0) } ?? 0
            if let meridiem = group(pattern.meridiemGroup)?.lowercased() {
                if meridiem == "pm" && hour < 12 { hour += 12 }
                if meridiem == "am" && hour == 12 { hour = 0 }
            }
            guard (0...23).contains(hour), (0...59).contains(minute) else { continue }
            guard let fullRange = Range(match.range(at: 0), in: text) else { continue }
            return (hour, minute, String(text[fullRange]))
        }
        return nil
    }

    private func matchPartOfDay(in text: String) -> (hour: Int, minute: Int, text: String)? {
        let mapping: [(String, Int)] = [
            ("morning", 9), ("afternoon", 15), ("evening", 19), ("night", 21), ("midnight", 0)
        ]
        for (word, hour) in mapping where text.contains(" \(word) ") {
            return (hour, 0, word)
        }
        return nil
    }

    private func matchRelative(in text: String) -> (component: Calendar.Component, value: Int, text: String, unitIsPrecise: Bool)? {
        let pattern = #"\bin\s+(\d{1,3})\s*(minute|min|hour|hr|day|week|month)s?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let fullRange = Range(match.range(at: 0), in: text),
              let value = Int(text[valueRange]) else { return nil }
        let unit = String(text[unitRange])
        let component: Calendar.Component
        switch unit {
        case "minute", "min": component = .minute
        case "hour", "hr": component = .hour
        case "day": component = .day
        case "week": component = .weekOfYear
        default: component = .month
        }
        return (component, value, String(text[fullRange]), component == .minute || component == .hour)
    }

    private func matchWeekday(in text: String) -> (weekday: RecurrenceRule.Weekday, text: String)? {
        let names = ["sunday", "sun", "monday", "mon", "tuesday", "tues", "wednesday", "wed",
                     "thursday", "thu", "thurs", "friday", "fri", "saturday", "sat"]
        for name in names where text.contains(" \(name) ") || text.contains(" \(name),") {
            if let weekday = RecurrenceRule.Weekday(name: name) { return (weekday, name) }
        }
        return nil
    }

    private func matchWeekly(in text: String) -> (rule: RecurrenceRule, text: String)? {
        // "every day", "every weekday", "every sunday", "every 2 weeks on monday"
        if text.contains(" every weekday ") {
            return (RecurrenceRule(frequency: .weekly,
                                   weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday]),
                    "every weekday")
        }
        guard text.contains(" every ") else { return nil }
        if text.contains(" every day ") || text.contains(" daily ") {
            return (.daily, "every day")
        }
        if text.contains(" every month ") { return (.monthly(interval: 1), "every month") }
        if text.contains(" every year ") { return (.yearly(interval: 1), "every year") }
        for name in ["sunday", "sun", "monday", "mon", "tuesday", "tues", "wednesday", "wed",
                     "thursday", "thu", "thurs", "friday", "fri", "saturday", "sat"] {
            if text.contains(" every \(name) ") || text.contains(" every \(name)s ") {
                if let weekday = RecurrenceRule.Weekday(name: name) {
                    return (RecurrenceRule(frequency: .weekly, weekdays: [weekday]), "every \(name)")
                }
            }
        }
        if let every = matchEveryInterval(in: text) { return every }
        return nil
    }

    private func matchEveryInterval(in text: String) -> (rule: RecurrenceRule, text: String)? {
        let pattern = #"\bevery\s+(\d{1,2})\s*(day|week|month|year)s?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let fullRange = Range(match.range(at: 0), in: text),
              let value = Int(text[valueRange]) else { return nil }
        let unit = String(text[unitRange])
        let frequency: RecurrenceRule.Frequency
        switch unit {
        case "day": frequency = .daily
        case "week": frequency = .weekly
        case "month": frequency = .monthly
        default: frequency = .yearly
        }
        return (RecurrenceRule(frequency: frequency, interval: value), String(text[fullRange]))
    }

    private func matchAbsoluteDate(in text: String, now: Date) -> (date: Date, text: String)? {
        // 24/12, 24-12-2026, december 5
        if let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b"#) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let dayRange = Range(match.range(at: 1), in: text),
               let monthRange = Range(match.range(at: 2), in: text),
               let day = Int(text[dayRange]), let month = Int(text[monthRange]), (1...12).contains(month), (1...31).contains(day) {
                var year = calendar.component(.year, from: now)
                if match.numberOfRanges > 3, let yearRange = Range(match.range(at: 3), in: text), let parsedYear = Int(text[yearRange]) {
                    year = parsedYear < 100 ? 2000 + parsedYear : parsedYear
                }
                if let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
                    let adjusted = date < calendar.startOfDay(for: now) ? calendar.date(byAdding: .year, value: 1, to: date) ?? date : date
                    return (adjusted, String(text[Range(match.range(at: 0), in: text)!]))
                }
            }
        }
        // "december 5" / "5 december"
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        let shortMonths = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        for (index, month) in months.enumerated() where text.contains(" \(month) ") {
            if let day = dayNumberNear(text: text, marker: month) {
                let year = calendar.component(.year, from: now)
                if let date = calendar.date(from: DateComponents(year: year, month: index + 1, day: day)) {
                    let adjusted = date < calendar.startOfDay(for: now) ? calendar.date(byAdding: .year, value: 1, to: date) ?? date : date
                    return (adjusted, "\(month) \(day)")
                }
            }
        }
        for (index, month) in shortMonths.enumerated() where text.contains(" \(month) ") {
            if let day = dayNumberNear(text: text, marker: month) {
                if let date = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: index + 1, day: day)) {
                    let adjusted = date < calendar.startOfDay(for: now) ? calendar.date(byAdding: .year, value: 1, to: date) ?? date : date
                    return (adjusted, "\(month) \(day)")
                }
            }
        }
        return nil
    }

    private func dayNumberNear(text: String, marker: String) -> Int? {
        let tokens = text.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        guard let index = tokens.firstIndex(where: { $0 == marker || $0 == marker + "," }) else { return nil }
        let neighbours = [index + 1, index - 1].compactMap { $0 >= 0 && $0 < tokens.count ? tokens[$0] : nil }
        for neighbour in neighbours {
            let digits = neighbour.filter { $0.isNumber }
            if let day = Int(digits), (1...31).contains(day) { return day }
        }
        return nil
    }

    private func nextDate(for weekday: RecurrenceRule.Weekday, after reference: Date, includingToday: Bool) -> Date? {
        for offset in (includingToday ? 0 : 1)...7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: reference) else { continue }
            if calendar.component(.weekday, from: candidate) == weekday.rawValue {
                return calendar.startOfDay(for: candidate)
            }
        }
        return nil
    }

    private func combine(date: Date, time: DateComponents) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = time.hour ?? 9
        components.minute = time.minute ?? 0
        components.second = 0
        return calendar.date(from: components) ?? date
    }
}
