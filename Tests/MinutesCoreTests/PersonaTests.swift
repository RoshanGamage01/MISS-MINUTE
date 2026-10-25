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

    func testDefaultPersonaIsMissMinute() {
        XCTAssertTrue(Persona.defaultPrompt.contains("Miss Minute"))
        XCTAssertTrue(Persona.defaultPrompt.lowercased().contains("southern"))
    }

    func testLegacyPersonaAndRetiredModelMigrate() {
        var settings = AppSettings(
            provider: .anthropic,
            model: "claude-3-5-haiku-latest",
            personaPrompt: "You are Minutes, a cheerful cartoon-clock desktop companion with warm Southern charm"
        )
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.personaPrompt, Persona.defaultPrompt)
        XCTAssertEqual(settings.model, ProviderKind.anthropic.defaultModel)
    }

    func testV2AgentPersonaUpgradesToFriendlyDefault() {
        var settings = AppSettings(personaPrompt: "You are Miss Minute. You are not a chatbot: you can see their screen and operate their computer like a capable human assistant.")
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.personaPrompt, Persona.defaultPrompt)
        XCTAssertFalse(Persona.isLegacyDefault(Persona.defaultPrompt))
    }

    func testCustomPersonaIsKept() {
        var settings = AppSettings(personaPrompt: "Be terse.")
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.personaPrompt, "Be terse.")
    }

    func testOldSettingsJSONDecodesWithDefaults() throws {
        let json = #"{"provider":"ollama","model":"llama3.2","voiceEnabled":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.voiceEnabled)
        XCTAssertEqual(settings.characterSkin, .hologram)
        XCTAssertEqual(settings.listenHotKey, .optionShiftSpace)
    }
}
