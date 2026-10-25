import XCTest
@testable import MinutesCore

final class AutonomyTests: XCTestCase {
    func testChecksAfterActingWithoutLooking() {
        XCTAssertTrue(Autonomy.needsCheck(toolsUsed: ["open_url"]))
        XCTAssertTrue(Autonomy.needsCheck(toolsUsed: ["look_at_screen", "click"]))
        XCTAssertFalse(Autonomy.needsCheck(toolsUsed: ["click", "look_at_screen"]))
        XCTAssertFalse(Autonomy.needsCheck(toolsUsed: ["run_shell"]), "a command's output is its own check")
        XCTAssertFalse(Autonomy.needsCheck(toolsUsed: ["add_task", "list_tasks"]))
        XCTAssertFalse(Autonomy.needsCheck(toolsUsed: []))
    }

    func testCatchesHandingTheChoiceBack() {
        XCTAssertTrue(Autonomy.handedBack(reply: "YouTube's open, hon! What would you like me to play?", request: "play music on youtube"))
        XCTAssertTrue(Autonomy.handedBack(reply: "Which song do you want?", request: "Play a song for me"))
        XCTAssertTrue(Autonomy.handedBack(reply: "Sure! Let me know what kind of app you're after.", request: "build me an app"))
    }

    func testAskingIsFineForQuestionsAndSensitiveTasks() {
        XCTAssertFalse(Autonomy.handedBack(reply: "What would you like to do next?", request: "what's the time?"))
        XCTAssertFalse(Autonomy.handedBack(reply: "Which address should I send it to?", request: "send an email to Sam"))
        XCTAssertFalse(Autonomy.handedBack(reply: "It's playing now!", request: "play some lofi"))
    }

    func testFindsVideoIDsInResultsPage() {
        let html = #"{"adSlot":{"videoId":"AAAAAAAAAAA"}}...{"videoRenderer":{"videoId":"jfKfPfyJRdk","thumbnail":{}}},{"videoRenderer":{"videoId":"5qap5aO4i9A"}},{"videoRenderer":{"videoId":"jfKfPfyJRdk"}}"#
        XCTAssertEqual(MediaSearch.videoIDs(inResultsPage: html), ["jfKfPfyJRdk", "5qap5aO4i9A"])
        XCTAssertEqual(MediaSearch.videoIDs(inResultsPage: #"x "videoId":"dQw4w9WgXcQ" y"#), ["dQw4w9WgXcQ"])
        XCTAssertTrue(MediaSearch.videoIDs(inResultsPage: "<html></html>").isEmpty)
        XCTAssertEqual(MediaSearch.searchURL("lofi beats").absoluteString, "https://www.youtube.com/results?search_query=lofi%20beats")
    }

    func testSettingsMigrateToWorkingOnHerOwn() throws {
        XCTAssertEqual(AppSettings.default.computerControl, .auto)
        let json = #"{"settingsVersion":4,"computerControl":"ask"}"#
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.computerControl, .auto)
        var off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"settingsVersion":4,"computerControl":"off"}"#.utf8))
        off.migrateLegacyValues()
        XCTAssertEqual(off.computerControl, .off, "an explicit Off stays off")
    }

    func testOldPersonaUpgrades() {
        var settings = AppSettings(personaPrompt: "…To do something on the computer, work carefully like a person would: look, take one action, check it worked…")
        settings.migrateLegacyValues()
        XCTAssertEqual(settings.personaPrompt, Persona.defaultPrompt)
        XCTAssertFalse(Persona.isLegacyDefault(Persona.defaultPrompt))
    }

    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    @MainActor
    func testHandedBackChoiceIsPushedToAct() async {
        var played: String?
        let registry = ToolRegistry()
        registry.register(AgentTool(spec: .object("play_youtube", "play")) { args in
            played = args["query"]?.stringValue
            return .ok("Playing")
        })
        registry.register(AgentTool(spec: .object("look_at_screen", "look")) { _ in .ok("It's playing.") })
        let provider = ScriptedProvider([
            [.textDelta("Ooh fun! What would you like to listen to?"), .finished(stop: .endTurn, rawContent: nil)],
            [.toolCall(ToolCall(id: "1", name: "play_youtube", arguments: ["query": "lofi hip hop radio"])), .finished(stop: .toolUse, rawContent: nil)],
            [.toolCall(ToolCall(id: "2", name: "look_at_screen", arguments: [:])), .finished(stop: .toolUse, rawContent: nil)],
            [.textDelta("Lofi's on, sugar!"), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let chat = ChatService(store: tempStore(), tools: registry, providerFactory: { provider })
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("play some music for me")
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(played, "lofi hip hop radio")
        XCTAssertEqual(provider.requests.count, 4, "looked after playing, so no extra check")
    }

    @MainActor
    func testContinueWorkQueuesBehindARunningTurn() async {
        let provider = ScriptedProvider([
            [.textDelta("Building it now."), .finished(stop: .endTurn, rawContent: nil)],
            [.textDelta("It works! Your app is ready."), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let chat = ChatService(store: tempStore(), providerFactory: { provider })
        var replies: [String] = []
        let done = expectation(description: "two replies")
        done.expectedFulfillmentCount = 2
        chat.onReply = { replies.append($0); done.fulfill() }
        chat.send("build me a timer app")
        chat.continueWork("(Note from the app: coding job #1 finished.)")
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(replies, ["Building it now.", "It works! Your app is ready."])
        XCTAssertTrue(chat.conversation.messages.contains { $0.isHidden == true && $0.content.contains("coding job") })
        XCTAssertFalse(chat.visibleMessages.contains { $0.content.contains("coding job") })
    }
}
