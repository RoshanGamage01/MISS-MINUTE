import XCTest
@testable import MinutesCore

final class FollowThroughTests: XCTestCase {
    // Replies taken from a real session where Gemma talked instead of acting.
    func testCatchesPromisesAndClaimsWithoutTools() {
        XCTAssertEqual(FollowThrough.gap(in: "I'm just as ready as a Sunday brunch, sugar! Give me one quick second to check if those permissions are all set, and then I'll dive right into your code."), .promised)
        XCTAssertEqual(FollowThrough.gap(in: "Since I'm feeling inspired, I'll start by taking a little peek at your project files."), .promised)
        XCTAssertEqual(FollowThrough.gap(in: "You got it, honey! I've opened up YouTube for you."), .claimed)
        XCTAssertEqual(FollowThrough.gap(in: "Let me check your calendar real quick!"), .promised)
    }

    func testLeavesOrdinaryRepliesAlone() {
        XCTAssertNil(FollowThrough.gap(in: "That's perfectly fine, hon! I'll just be right here hanging out on your desktop. You just holler if you need anything at all!"))
        XCTAssertNil(FollowThrough.gap(in: "How about some Lo-Fi beats, or maybe some upbeat jazz? Tell me which vibe you're feeling!"))
        XCTAssertNil(FollowThrough.gap(in: "Want me to open it for you?"))
        XCTAssertNil(FollowThrough.gap(in: "Let me know if you need anything else, sugar!"))
        XCTAssertNil(FollowThrough.gap(in: "It's 3:15 in the afternoon."))
    }

    func testInstantAckKinds() {
        XCTAssertEqual(InstantAck.kind(of: "Open YouTube and play some lofi"), .task)
        XCTAssertEqual(InstantAck.kind(of: "Can you pick a song for me"), .task)
        XCTAssertEqual(InstantAck.kind(of: "OK, go ahead and will"), .task)
        XCTAssertEqual(InstantAck.kind(of: "What's on my calendar today"), .question)
        XCTAssertEqual(InstantAck.kind(of: "Are you done now?"), .question)
        XCTAssertNil(InstantAck.kind(of: "Hi"))
        XCTAssertNil(InstantAck.kind(of: "Nothing"))
        XCTAssertNil(InstantAck.kind(of: "thanks!"))
        XCTAssertNil(InstantAck.kind(of: "I'm a bit tired today"))
    }

    func testWakePhrase() {
        XCTAssertEqual(WakePhrase.command(in: "Hey Minute, what's the time?"), "what's the time?")
        XCTAssertEqual(WakePhrase.command(in: "hey minute"), "")
        XCTAssertEqual(WakePhrase.command(in: "OK Miss Minute open Safari"), "open Safari")
        XCTAssertEqual(WakePhrase.command(in: "Hey Minnie, set a timer for ten minutes"), "set a timer for ten minutes")
        XCTAssertEqual(WakePhrase.command(in: "so anyway hey minute play music"), "play music")
        XCTAssertNil(WakePhrase.command(in: "wait a minute, I'll be right back"))
        XCTAssertNil(WakePhrase.command(in: "give me a minute"))
        XCTAssertNil(WakePhrase.command(in: "the meeting starts in a minute"))
    }

    // MARK: - Chat loop

    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    @MainActor
    func testPromiseWithoutToolIsNudgedIntoActing() async {
        var ran = false
        let registry = ToolRegistry()
        registry.register(AgentTool(spec: .object("open_url", "open")) { _ in ran = true; return .ok("opened") })
        let provider = ScriptedProvider([
            [.textDelta("Give me one quick second to pull that up!"), .finished(stop: .endTurn, rawContent: nil)],
            [.toolCall(ToolCall(id: "1", name: "open_url", arguments: [:])), .finished(stop: .toolUse, rawContent: nil)],
            [.textDelta("There you go!"), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let chat = ChatService(store: tempStore(), tools: registry, providerFactory: { provider })
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("open youtube")
        await fulfillment(of: [replied], timeout: 5)

        XCTAssertTrue(ran, "the nudge got the tool called")
        // open_url confirms itself, so there's no extra check round after it.
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(chat.conversation.messages.filter { $0.isHidden == true }.count, 1)
        XCTAssertFalse(chat.visibleMessages.contains { $0.isHidden == true })
    }

    @MainActor
    func testNudgesOnlyOnce() async {
        let registry = ToolRegistry()
        registry.register(AgentTool(spec: .object("open_url", "open")) { _ in .ok("opened") })
        let provider = ScriptedProvider([
            [.textDelta("Let me check that!"), .finished(stop: .endTurn, rawContent: nil)],
            [.textDelta("Let me check that again!"), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let chat = ChatService(store: tempStore(), tools: registry, providerFactory: { provider })
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("check my mail")
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(provider.requests.count, 2)
    }

    @MainActor
    func testSpokenRequestGetsInstantAckBeforeTheModel() async {
        var spoken: [(String, Bool)] = []
        let provider = ScriptedProvider([[.textDelta("It's on your screen now."), .finished(stop: .endTurn, rawContent: nil)]])
        let chat = ChatService(store: tempStore(), providerFactory: { provider })
        chat.onSpeak = { spoken.append(($0, $1)) }
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("Open my calendar", inputMode: "spoken")
        // Spoken synchronously, before the model has produced anything.
        XCTAssertEqual(spoken.first?.0, InstantAck.taskLines[0])
        XCTAssertEqual(spoken.first?.1, false)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(spoken.map(\.0), [InstantAck.taskLines[0], "It's on your screen now."])
        XCTAssertEqual(spoken.last?.1, true, "the answer queues after the acknowledgement")
        XCTAssertTrue(chat.conversation.messages.first?.contextNote?.contains("already said") == true)
    }

    @MainActor
    func testTypedAndSmallTalkGetNoInstantAck() async {
        var spoken: [String] = []
        let provider = ScriptedProvider([
            [.textDelta("Hey there!"), .finished(stop: .endTurn, rawContent: nil)],
            [.textDelta("Done."), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let chat = ChatService(store: tempStore(), providerFactory: { provider })
        chat.onSpeak = { text, _ in spoken.append(text) }
        var replied = expectation(description: "reply1")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("Hi", inputMode: "spoken")
        await fulfillment(of: [replied], timeout: 5)
        replied = expectation(description: "reply2")
        chat.send("open my calendar", inputMode: "typed")
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(spoken, ["Hey there!", "Done."])
    }

    // MARK: - Trace with an acknowledgement playing before the model answers

    @MainActor
    func testTraceWaitsForModelWhenAckPlaysFirst() {
        let trace = LatencyTrace()
        var clock: TimeInterval = 10
        trace.now = { clock }
        var reports: [LatencyTrace.Report] = []
        trace.sink = { reports.append($0) }
        trace.begin(origin: "spoken")
        trace.mark(.firstChunk)
        clock = 10.05; trace.finish(engine: "Mac")
        XCTAssertTrue(reports.isEmpty, "waits for the model")
        clock = 11.2; trace.mark(.firstToken)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].ms(.firstAudio), 50)
        XCTAssertEqual(reports[0].ms(.firstToken), 1200)
    }
}
