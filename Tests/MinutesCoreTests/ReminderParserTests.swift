import XCTest
@testable import MinutesCore

final class ReminderParserTests: XCTestCase {
    private var calendar: Calendar!
    private var parser: ReminderParser!
    private var now: Date!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = cal
        parser = ReminderParser(calendar: cal)
        now = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12, minute: 0))!
    }

    func testParseInMinutes() throws {
        let parsed = try XCTUnwrap(parser.parse("remind me in 20 minutes to stretch", now: now))
        XCTAssertEqual(parsed.text, "stretch")
        XCTAssertEqual(parsed.fireAt.timeIntervalSince(now), 20 * 60, accuracy: 0.5)
    }

    func testParseInHoursAndMinutes() throws {
        let parsed = try XCTUnwrap(
            parser.parse("Remind me in 1 hour and 15 minutes to check the oven", now: now)
        )
        XCTAssertEqual(parsed.text, "check the oven")
        XCTAssertEqual(parsed.fireAt.timeIntervalSince(now), 75 * 60, accuracy: 0.5)
    }

    func testParseTrailingDuration() throws {
        let parsed = try XCTUnwrap(parser.parse("remind me to call mom in 5 mins", now: now))
        XCTAssertEqual(parsed.text, "call mom")
        XCTAssertEqual(parsed.fireAt.timeIntervalSince(now), 5 * 60, accuracy: 0.5)
    }

    func testParseClockTimePM() throws {
        let parsed = try XCTUnwrap(parser.parse("remind me at 3:30pm to leave", now: now))
        XCTAssertEqual(parsed.text, "leave")
        let hour = calendar.component(.hour, from: parsed.fireAt)
        let minute = calendar.component(.minute, from: parsed.fireAt)
        XCTAssertEqual(hour, 15)
        XCTAssertEqual(minute, 30)
    }

    func testParseClockTimeRollsToNextDay() throws {
        let parsed = try XCTUnwrap(parser.parse("remind me at 9:00am to stretch", now: now))
        XCTAssertEqual(parsed.text, "stretch")
        // 9am is before noon "now", so should roll to tomorrow.
        XCTAssertGreaterThan(parsed.fireAt, now)
        let day = calendar.component(.day, from: parsed.fireAt)
        XCTAssertEqual(day, 26)
    }

    func testLooksLikeReminder() {
        XCTAssertTrue(parser.looksLikeReminder("remind me later"))
        XCTAssertTrue(parser.looksLikeReminder("Nudge me in a bit"))
        XCTAssertFalse(parser.looksLikeReminder("what's the weather"))
    }

    func testNonReminderReturnsNil() {
        XCTAssertNil(parser.parse("tell me a joke", now: now))
        XCTAssertNil(parser.parse("remind me someday", now: now))
    }
}
