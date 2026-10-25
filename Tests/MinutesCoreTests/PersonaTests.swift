import XCTest
@testable import MinutesCore

final class PersonaTests: XCTestCase {
    func testTimeAwarePrefixIncludesPeriod() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8))!
        let text = Persona.timeAwarePrefix(now: morning, calendar: calendar)
        XCTAssertTrue(text.contains("morning"))
        XCTAssertTrue(text.contains("Current local time"))
    }

    func testDefaultPersonaMentionsMinutes() {
        XCTAssertTrue(Persona.defaultPrompt.contains("Minutes"))
        XCTAssertTrue(Persona.defaultPrompt.lowercased().contains("southern"))
    }
}
