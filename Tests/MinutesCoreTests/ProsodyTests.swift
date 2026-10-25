import XCTest
@testable import MinutesCore

final class ProsodyTests: XCTestCase {
    func testFlatWhenExpressivenessIsZero() {
        XCTAssertEqual(Prosody.forLine("Great news!", index: 3, expressiveness: 0), .neutral)
    }

    func testExclamationsAndQuestionsLift() {
        let excited = Prosody.forLine("We did it, sugar!", index: 0, expressiveness: 1)
        let question = Prosody.forLine("How's your day going so far?", index: 0, expressiveness: 1)
        let thoughtful = Prosody.forLine("Hmm, let me think about that for a second.", index: 0, expressiveness: 1)
        XCTAssertGreaterThan(excited.pitch, 1)
        XCTAssertGreaterThan(question.pitch, 1)
        XCTAssertGreaterThan(excited.rate, thoughtful.rate)
        XCTAssertLessThan(thoughtful.rate, 1)
    }

    func testNeighbouringLinesDifferButStayInRange() {
        let lines = (0..<20).map { Prosody.forLine("Your meeting starts at ten.", index: $0, expressiveness: 1) }
        XCTAssertGreaterThan(Set(lines.map(\.rate)).count, 10, "lines vary")
        for p in lines {
            XCTAssertTrue((0.85...1.18).contains(p.rate))
            XCTAssertTrue((0.88...1.2).contains(p.pitch))
        }
        // Deterministic: the same line in the same position sounds the same.
        XCTAssertEqual(lines[4], Prosody.forLine("Your meeting starts at ten.", index: 4, expressiveness: 1))
    }

    func testOldSettingsDecodeWithVoiceDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"voiceEnabled":true}"#.utf8))
        XCTAssertEqual(settings.voiceExpressiveness, 0.6)
        XCTAssertEqual(settings.sayVoice, "")
    }
}
