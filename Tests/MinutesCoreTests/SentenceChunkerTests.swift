import XCTest
@testable import MinutesCore

final class SentenceChunkerTests: XCTestCase {
    func testEmitsSentencesAsTheyComplete() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.feed("Well hey there, sug"), [])
        XCTAssertEqual(chunker.feed("ar! I put that on your list. And"), ["Well hey there, sugar!", "I put that on your list."])
        XCTAssertEqual(chunker.flush(), "And")
        XCTAssertNil(chunker.flush())
    }

    func testDoesNotSplitNumbersOrShortAbbreviations() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.feed("Version 3.5 is out. "), ["Version 3.5 is out."])
        XCTAssertEqual(chunker.feed("Mr. Smith called about lunch. "), ["Mr. Smith called about lunch."])
    }

    func testClosingQuotesStayWithSentence() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.feed("She said \"see you at noon.\" Then left."), ["She said \"see you at noon.\""])
    }

    func testFirstChunkCanEndAtAClause() {
        var chunker = SentenceChunker(firstClauseLength: 20)
        XCTAssertEqual(chunker.feed("Well hey there sugar, let me check that "), ["Well hey there sugar,"])
        // Later chunks wait for a full sentence.
        XCTAssertEqual(chunker.feed("for you, okay? Done"), ["let me check that for you, okay?"])
    }

    func testV4MovesSlowElevenLabsModelToFlash() throws {
        let json = #"{"settingsVersion":3,"elevenLabsModel":"eleven_multilingual_v2"}"#
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.autoMemory)
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.elevenLabsModel, "eleven_flash_v2_5")
    }

    func testNewSettingsVersionMovesRoboticVoiceToAuto() throws {
        let json = #"{"voiceEngine":"system"}"#
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.settingsVersion, 1)
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.voiceEngine, .auto)
        XCTAssertEqual(settings.settingsVersion, AppSettings.currentVersion)

        // A deliberate choice made on the current version is respected.
        settings.voiceEngine = .system
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.voiceEngine, .system)
    }
}
