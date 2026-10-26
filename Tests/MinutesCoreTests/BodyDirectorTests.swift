import XCTest
@testable import MinutesCore

final class BodyDirectorTests: XCTestCase {
    let director = BodyDirector()

    func testToolKinds() {
        XCTAssertEqual(BodyDirector.kind(of: "open_app"), .contextSwitch)
        XCTAssertEqual(BodyDirector.kind(of: "click"), .screenAction)
        XCTAssertEqual(BodyDirector.kind(of: "look_at_screen"), .observe)
        XCTAssertEqual(BodyDirector.kind(of: "start_coding_agent"), .coding)
        XCTAssertEqual(BodyDirector.kind(of: "search_web"), .lookup)
        XCTAssertEqual(BodyDirector.kind(of: "add_task"), .bookkeeping)
        XCTAssertEqual(BodyDirector.kind(of: "something_new"), .other)
    }

    func testSwitchingAppsTeleportsToTheNewWindowOnceItsOpen() {
        let cue = director.cue(for: .toolFinished(name: "open_app", isError: false))
        XCTAssertEqual(cue?.travel, .teleport)
        XCTAssertEqual(cue?.destination, .activeWindow)
        XCTAssertEqual(cue?.gesture, .point)
        XCTAssertGreaterThan(cue?.delay ?? 0, 0)
    }

    func testActingAtAPointGlidesBesideItAndPoints() {
        let cue = director.cue(for: .actingAt(x: 300, y: 400))
        XCTAssertEqual(cue?.destination, .screenPoint(x: 300, y: 400))
        XCTAssertEqual(cue?.travel, .glide)
        XCTAssertEqual(cue?.gesture, .point)
    }

    func testLookingAtTheScreenPeers() {
        XCTAssertEqual(director.cue(for: .toolStarted(name: "read_screen"))?.gesture, .peer)
    }

    func testLookupsGetTheThinkingGesture() {
        XCTAssertEqual(director.cue(for: .toolStarted(name: "search_web"))?.gesture, .think)
        XCTAssertEqual(director.cue(for: .backgroundJobProgress)?.gesture, .think)
    }

    func testCodingLooksFocused() {
        XCTAssertEqual(director.cue(for: .toolStarted(name: "run_shell"))?.aura, .focused)
        XCTAssertEqual(director.steadyAura(mood: .working, backgroundJobsRunning: 0, lastToolKind: .coding), .focused)
        XCTAssertEqual(director.steadyAura(mood: .idle, backgroundJobsRunning: 1, lastToolKind: nil), .focused)
    }

    func testProcessingGlowOnlyWhileWorking() {
        XCTAssertEqual(director.steadyAura(mood: .thinking, backgroundJobsRunning: 0, lastToolKind: nil), .processing)
        XCTAssertEqual(director.steadyAura(mood: .working, backgroundJobsRunning: 0, lastToolKind: .lookup), .processing)
        XCTAssertEqual(director.steadyAura(mood: .idle, backgroundJobsRunning: 0, lastToolKind: nil), BodyAura.none)
        XCTAssertEqual(director.steadyAura(mood: .talking, backgroundJobsRunning: 0, lastToolKind: .coding), BodyAura.none)
    }

    func testSuccessGetsThumbsUpAndFinishingCelebrates() {
        XCTAssertEqual(director.cue(for: .toolFinished(name: "add_task", isError: false))?.gesture, .thumbsUp)
        let done = director.cue(for: .toolFinished(name: "complete_task", isError: false))
        XCTAssertEqual(done?.gesture, .celebrate)
        XCTAssertEqual(done?.aura, .celebrating)
        XCTAssertEqual(director.cue(for: .backgroundJobFinished(success: true))?.gesture, .celebrate)
        XCTAssertEqual(director.cue(for: .turnCompleted(reply: "Done!", toolsUsed: ["click"]))?.gesture, .thumbsUp)
    }

    func testFailuresShrugWithAnAlert() {
        let cue = director.cue(for: .toolFinished(name: "click", isError: true))
        XCTAssertEqual(cue?.gesture, .shrug)
        XCTAssertEqual(cue?.aura, .alert)
        XCTAssertEqual(director.cue(for: .turnFailed)?.gesture, .shrug)
        XCTAssertEqual(director.cue(for: .backgroundJobFinished(success: false))?.gesture, .shrug)
    }

    func testPointsWhenReferringToAFile() {
        let cue = director.cue(for: .turnCompleted(reply: "Saved it to ~/Desktop/notes.md, sugar.", toolsUsed: []))
        XCTAssertEqual(cue?.gesture, .point)
        XCTAssertEqual(cue?.destination, .activeWindow)
    }

    func testPlainChatDoesNothing() {
        XCTAssertNil(director.cue(for: .turnCompleted(reply: "Morning, hon! About ~5 minutes left.", toolsUsed: [])))
    }

    func testFileMentionDetection() {
        XCTAssertTrue(BodyDirector.mentionsFile("Check `AppModel.swift`"))
        XCTAssertTrue(BodyDirector.mentionsFile("It's in /Users/me/projects/app"))
        XCTAssertTrue(BodyDirector.mentionsFile("open ./build/log"))
        XCTAssertFalse(BodyDirector.mentionsFile("Sounds good, e.g. tomorrow at 5."))
        XCTAssertFalse(BodyDirector.mentionsFile("Version 2.1 is out"))
    }
}
