import XCTest
@testable import JarvisCore

final class ReminderTests: XCTestCase {

    // MARK: Recurrence engine

    func testWeeklyRecurrencePicksTheCorrectWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        // 2023-11-14 is a Tuesday.
        let tuesday = Date(timeIntervalSince1970: 1_700_000_000)
        let rule = RecurrenceRule.weekly(on: [.sunday])
        let next = try XCTUnwrap(rule.nextOccurrence(after: tuesday, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: next), RecurrenceRule.Weekday.sunday.rawValue)
        XCTAssertTrue(next > tuesday)
    }

    func testEveryTwoWeeksHonoursTheInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 9))!   // Monday
        let rule = RecurrenceRule(frequency: .weekly, interval: 2, weekdays: [.monday])
        let occurrences = rule.occurrences(startingAt: start, limit: 3, calendar: calendar)
        XCTAssertEqual(occurrences.count, 3)
        for pair in zip(occurrences, occurrences.dropFirst()) {
            let weeks = calendar.dateComponents([.day], from: pair.0, to: pair.1).day ?? 0
            XCTAssertEqual(weeks, 14, "a two-week interval must be 14 days apart")
        }
    }

    func testMonthlyRecurrenceHandlesMonthLengths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let jan31 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 8))!
        let rule = RecurrenceRule.monthly()
        let next = try XCTUnwrap(rule.nextOccurrence(after: jan31, calendar: calendar))
        // Calendar arithmetic clamps to the end of February rather than inventing a 31st.
        XCTAssertEqual(calendar.component(.month, from: next), 2)
        XCTAssertLessThanOrEqual(calendar.component(.day, from: next), 29)
    }

    func testDailyRecurrenceAcrossDaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Europe/London")!
        calendar.timeZone = zone
        // 2026-03-28 09:00 London; DST starts 2026-03-29.
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 9))!
        let rule = RecurrenceRule.daily
        let next = try XCTUnwrap(rule.nextOccurrence(after: start, calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: next), 9, "local wall-clock time must be preserved across DST")
        XCTAssertEqual(calendar.component(.day, from: next), 29)
    }

    func testUnsupportedRecurrenceIsRejectedExplicitly() {
        // Only supported frequencies exist in the model — anything else cannot be constructed,
        // so a reminder can never be silently scheduled with the wrong rule.
        XCTAssertEqual(RecurrenceRule.Frequency.allCases.count, 4)
        XCTAssertNil(RecurrenceRule.Weekday(name: "caturday"))
    }

    // MARK: Natural-language parsing

    private func parser(_ zone: String = "Asia/Kolkata") -> DateTimeParser {
        DateTimeParser(timeZone: TimeZone(identifier: zone)!)
    }

    func testRelativePhrases() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let in20 = try XCTUnwrap(parser().parse("remind me in 20 minutes to stretch", now: now))
        XCTAssertEqual(in20.date.timeIntervalSince(now), 1200, accuracy: 1)
        let in2h = try XCTUnwrap(parser().parse("in 2 hours call mum", now: now))
        XCTAssertEqual(in2h.date.timeIntervalSince(now), 7200, accuracy: 1)
    }

    func testTomorrowAtClockTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = parser().parse("remind me tomorrow at 9am to study", now: now)
        let date = try? XCTUnwrap(parsed?.date)
        XCTAssertNotNil(date)
        XCTAssertEqual(calendar.component(.hour, from: date!), 9)
        XCTAssertEqual(calendar.component(.minute, from: date!), 0)
        let expectedDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        XCTAssertEqual(calendar.startOfDay(for: date!), expectedDay)
        XCTAssertTrue(parsed?.hadExplicitTime == true)
    }

    func testEverySundayRecurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let parsed = try XCTUnwrap(parser().parse("remind me every Sunday at 6pm to review my projects", now: now))
        let rule = try XCTUnwrap(parsed.recurrence)
        XCTAssertEqual(rule.frequency, .weekly)
        XCTAssertEqual(rule.weekdays, [.sunday])
        XCTAssertEqual(calendar.component(.weekday, from: parsed.date), RecurrenceRule.Weekday.sunday.rawValue)
        XCTAssertEqual(calendar.component(.hour, from: parsed.date), 18)
    }

    func testUnparseablePhraseReturnsNilSoTheAssistantCanAsk() {
        XCTAssertNil(parser().parse("remind me to do the thing at some point", now: Date()))
    }

    func testTimeZoneAwarenessAcrossZones() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T21:13:20Z
        let kolkata = try XCTUnwrap(parser("Asia/Kolkata").parse("tomorrow at 9am", now: now))
        let newYork = try XCTUnwrap(parser("America/New_York").parse("tomorrow at 9am", now: now))
        var kolkataCalendar = Calendar(identifier: .gregorian); kolkataCalendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        var newYorkCalendar = Calendar(identifier: .gregorian); newYorkCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(kolkataCalendar.component(.hour, from: kolkata.date), 9)
        XCTAssertEqual(newYorkCalendar.component(.hour, from: newYork.date), 9)
        XCTAssertNotEqual(kolkata.date, newYork.date, "the same phrase means different instants in different zones")
    }

    // MARK: Scheduling lifecycle

    func testSchedulingConfirmsTheNotificationAndPersists() async throws {
        let stack = makeReminderStack(now: Date(timeIntervalSince1970: 1_700_000_000))
        let receipt = try await stack.engine.create(fromNaturalLanguage: "remind me tomorrow at 9am to study")
        XCTAssertTrue(receipt.notificationConfirmed, "success is only claimed when the scheduler confirmed")
        XCTAssertEqual(stack.scheduler.scheduled.count, 1)
        XCTAssertEqual(try stack.engine.open().count, 1)
        XCTAssertEqual(receipt.reminder.title.lowercased(), "study")
    }

    func testSchedulingFailureIsReportedNotSwallowed() async throws {
        let stack = makeReminderStack(now: Date(timeIntervalSince1970: 1_700_000_000))
        stack.scheduler.failureForNextSchedule = .unavailable(reason: "Notifications are disabled for JARVIS.")
        let receipt = try await stack.engine.create(fromNaturalLanguage: "remind me tomorrow at 9am to study")
        XCTAssertFalse(receipt.notificationConfirmed)
        XCTAssertTrue(receipt.note.contains("could not be scheduled"))
        XCTAssertNotNil(receipt.reminder.lastError)
        XCTAssertEqual(try stack.engine.open().count, 1, "the reminder is still stored so nothing is lost")
    }

    func testCompleteRollsRecurringReminderForward() async throws {
        let stack = makeReminderStack(now: Date(timeIntervalSince1970: 1_700_000_000))
        let receipt = try await stack.engine.create(fromNaturalLanguage: "remind me every Sunday at 6pm to review my projects")
        let completed = try await stack.engine.complete(id: receipt.reminder.id)
        XCTAssertNotNil(completed.completedAt)
        let open = try stack.engine.open()
        XCTAssertEqual(open.count, 1, "the recurring reminder rolls forward")
        XCTAssertNotEqual(open.first?.id, receipt.reminder.id)
        XCTAssertEqual(open.first?.title.lowercased(), "review my projects")
    }

    func testCancelByNaturalLanguageMatch() async throws {
        let stack = makeReminderStack(now: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await stack.engine.create(fromNaturalLanguage: "remind me tomorrow at 9am to study")
        let cancelled = try await stack.engine.cancel(matching: "cancel my study reminder")
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertTrue(try stack.engine.open().isEmpty)
    }

    func testTodayAndTomorrowWindows() async throws {
        let stack = makeReminderStack(now: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await stack.engine.create(fromNaturalLanguage: "remind me tomorrow at 9am to study")
        XCTAssertTrue(try stack.engine.tomorrow().count == 1)
        XCTAssertTrue(try stack.engine.today().isEmpty)
    }

    func testReminderInThePastIsRejected() async throws {
        let stack = makeReminderStack(now: Date(timeIntervalSince1970: 1_700_000_000))
        do {
            _ = try await stack.engine.schedule(title: "Too late", dueAt: Date(timeIntervalSince1970: 1_600_000_000))
            XCTFail("scheduling a past reminder must fail loudly")
        } catch let error as JarvisError {
            XCTAssertEqual(error, .invalidArguments("that time is already in the past"))
        }
    }

    func testReconcileDetectsDriftBetweenStoreAndOS() async throws {
        let stack = makeReminderStack(now: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await stack.engine.create(fromNaturalLanguage: "remind me tomorrow at 9am to study")
        // Simulate the OS losing the notification (restore, reinstall).
        let drifted = await stack.engine.reconcile()
        XCTAssertTrue(drifted.isEmpty, "immediately after scheduling there is no drift")
        stack.scheduler.reset()
        let afterLoss = await stack.engine.reconcile()
        XCTAssertEqual(afterLoss.count, 1, "drift is detected rather than assumed away")
    }
}
