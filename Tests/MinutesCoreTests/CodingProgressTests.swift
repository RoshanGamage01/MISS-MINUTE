import XCTest
@testable import MinutesCore

final class CodingProgressTests: XCTestCase {
    private func toolUse(_ name: String, _ input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"\#(name)","input":\#(input)}]}}"#
    }

    // MARK: Claude Code stream-json

    func testClaudeToolCallsBecomeShortSteps() {
        var parser = CodingProgressParser()
        XCTAssertEqual(parser.parse(#"{"type":"system","subtype":"init","model":"x"}"#), [.step("Getting started")])
        XCTAssertEqual(parser.parse(toolUse("Read", #"{"file_path":"/p/Sources/Mood.swift"}"#)), [.step("Reading Mood.swift")])
        XCTAssertEqual(parser.parse(toolUse("Edit", #"{"file_path":"/p/Autonomy.swift","old_string":"a","new_string":"b"}"#)),
                       [.step("Editing Autonomy.swift")])
        XCTAssertEqual(parser.parse(toolUse("Grep", #"{"pattern":"func observe"}"#)), [.step("Searching the code for “func observe”")])
        XCTAssertEqual(parser.parse(toolUse("Glob", #"{"pattern":"**/*.swift"}"#)), [.step("Looking around the project")])
    }

    func testWritingATestFileNamesWhatItTests() {
        var parser = CodingProgressParser()
        XCTAssertEqual(parser.parse(toolUse("Write", #"{"file_path":"/p/Tests/MoodTests.swift","content":""}"#)),
                       [.step("Writing tests for Mood.swift")])
        XCTAssertEqual(parser.parse(toolUse("Edit", #"{"file_path":"/p/src/app.test.ts"}"#)), [.step("Updating tests for app.ts")])
        XCTAssertEqual(parser.parse(toolUse("Write", #"{"file_path":"/p/test_utils.py"}"#)), [.step("Writing tests for utils.py")])
        XCTAssertEqual(parser.parse(toolUse("Write", #"{"file_path":"/p/Tests.swift"}"#)), [.step("Writing Tests.swift")])
    }

    func testEditsAfterTalkingAboutABugReadAsFixes() {
        var parser = CodingProgressParser()
        let note = #"{"type":"assistant","message":{"content":[{"type":"text","text":"The build fails because of a missing import.\nLet me fix it."}]}}"#
        XCTAssertEqual(parser.parse(note), [.note("The build fails because of a missing import.")])
        XCTAssertEqual(parser.parse(toolUse("Edit", #"{"file_path":"/p/Autonomy.swift"}"#)), [.step("Fixing Autonomy.swift")])
        _ = parser.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Now adding the settings screen."}]}}"#)
        XCTAssertEqual(parser.parse(toolUse("Edit", #"{"file_path":"/p/Settings.swift"}"#)), [.step("Editing Settings.swift")])
    }

    func testShellCommandsAreNamedByWhatTheyDo() {
        var parser = CodingProgressParser()
        XCTAssertEqual(parser.parse(toolUse("Bash", #"{"command":"cd /p && swift test 2>&1 | tail"}"#)), [.step("Running the tests")])
        XCTAssertEqual(parser.parse(toolUse("Bash", #"{"command":"npm run build"}"#)), [.step("Building the project")])
        XCTAssertEqual(parser.parse(toolUse("Bash", #"{"command":"npm install react"}"#)), [.step("Installing dependencies")])
        XCTAssertEqual(parser.parse(toolUse("Bash", #"{"command":"ls -la","description":"List the project files"}"#)),
                       [.step("List the project files")])
        XCTAssertEqual(parser.parse(toolUse("Bash", #"{"command":"echo hi"}"#)), [.step("Running `echo hi`")])
    }

    func testTodoListShowsTheItemInProgress() {
        var parser = CodingProgressParser()
        let todos = #"{"todos":[{"content":"Add model","status":"completed","activeForm":"Adding model"},{"content":"Write tests","status":"in_progress","activeForm":"Writing the tests"}]}"#
        XCTAssertEqual(parser.parse(toolUse("TodoWrite", todos)), [.step("Writing the tests")])
        XCTAssertEqual(parser.parse(toolUse("TodoWrite", #"{"todos":[]}"#)), [])
    }

    func testFailedToolResultsAndFinalReport() {
        var parser = CodingProgressParser()
        let failed = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"boom"}]}}"#
        XCTAssertEqual(parser.parse(failed), [.problem("Hit a snag, working around it")])
        let fine = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        XCTAssertEqual(parser.parse(fine), [])
        XCTAssertEqual(parser.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Built the app."}"#),
                       [.finished(result: "Built the app.", isError: false)])
        XCTAssertEqual(parser.parse(#"{"type":"result","subtype":"error_max_turns","result":""}"#),
                       [.finished(result: "", isError: true)])
    }

    func testOneMessageCanCarrySeveralEvents() {
        var parser = CodingProgressParser()
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the models first."},{"type":"tool_use","name":"Read","input":{"file_path":"/a/Mood.swift"}},{"type":"tool_use","name":"Read","input":{"file_path":"/a/Autonomy.swift"}}]}}"#
        XCTAssertEqual(parser.parse(line), [.note("Looking at the models first."), .step("Reading Mood.swift"), .step("Reading Autonomy.swift")])
    }

    func testIgnoresNoiseAndPlainText() {
        var parser = CodingProgressParser()
        XCTAssertEqual(parser.parse("Plain text output"), [])
        XCTAssertEqual(parser.parse("{not json"), [])
        XCTAssertEqual(parser.parse(#"{"type":"stream_event"}"#), [])
        XCTAssertEqual(parser.parse(toolUse("SomeNewTool", "{}")), [])
    }

    // MARK: cursor-agent stream-json

    func testCursorToolCalls() {
        var parser = CodingProgressParser()
        XCTAssertEqual(parser.parse(#"{"type":"tool_call","subtype":"started","call_id":"1","tool_call":{"readToolCall":{"args":{"path":"/p/Mood.swift"}}}}"#),
                       [.step("Reading Mood.swift")])
        XCTAssertEqual(parser.parse(#"{"type":"tool_call","subtype":"started","tool_call":{"writeToolCall":{"args":{"path":"/p/MoodTests.swift","fileText":""}}}}"#),
                       [.step("Writing tests for Mood.swift")])
        XCTAssertEqual(parser.parse(#"{"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"pytest -q"}}}}"#),
                       [.step("Running the tests")])
        XCTAssertEqual(parser.parse(#"{"type":"tool_call","subtype":"started","tool_call":{"function":{"name":"edit","arguments":"{\"path\":\"/p/a.swift\"}"}}}"#),
                       [.step("Editing a.swift")])
        // Completion events repeat the call; only the start is shown.
        XCTAssertEqual(parser.parse(#"{"type":"tool_call","subtype":"completed","tool_call":{"readToolCall":{"args":{"path":"/p/Mood.swift"}}}}"#), [])
    }

    // MARK: Log

    func testLogCollapsesRepeatsAndTracksCurrentStep() {
        var log = CodingProgressLog(limit: 3)
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(log.record("Reading Mood.swift", kind: .step, at: start))
        XCTAssertFalse(log.record("Reading Mood.swift", kind: .step, at: start))
        XCTAssertFalse(log.record("   ", kind: .note))
        log.record("Thinking it over", kind: .note, at: start.addingTimeInterval(5))
        XCTAssertEqual(log.currentStep, "Reading Mood.swift")
        log.record("Editing Mood.swift", kind: .step, at: start.addingTimeInterval(70))
        log.record("Running the tests", kind: .step, at: start.addingTimeInterval(192))
        XCTAssertEqual(log.entries.map(\.text), ["Thinking it over", "Editing Mood.swift", "Running the tests"])
        XCTAssertEqual(log.currentStep, "Running the tests")
        XCTAssertEqual(log.recent(1).map(\.text), ["Running the tests"])
        XCTAssertEqual(Set(log.entries.map(\.id)).count, 3)
        XCTAssertEqual(CodingProgressLog.line(for: log.entries[2], since: start), "[+03:12] Running the tests")
        XCTAssertEqual(CodingProgressLog.line(for: log.entries[0], since: start), "[+00:05]   “Thinking it over”")
    }

    // MARK: Pacing

    func testPacerKeepsBubblesRare() {
        var pacer = ProgressPacer(firstDelay: 30, interval: 60)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(pacer.next("Reading Mood.swift", startedAt: start, now: start.addingTimeInterval(10)), "too soon after start")
        XCTAssertEqual(pacer.next("Reading Mood.swift", startedAt: start, now: start.addingTimeInterval(31)), "Reading Mood.swift")
        XCTAssertNil(pacer.next("Editing Mood.swift", startedAt: start, now: start.addingTimeInterval(60)), "within the interval")
        XCTAssertEqual(pacer.next("Editing Mood.swift", startedAt: start, now: start.addingTimeInterval(95)), "Editing Mood.swift")
        XCTAssertNil(pacer.next("Editing Mood.swift", startedAt: start, now: start.addingTimeInterval(400)), "same line twice")
        XCTAssertNil(pacer.next(nil, startedAt: start, now: start.addingTimeInterval(500)))
    }

    // MARK: Line splitting

    func testLineSplitterHoldsPartialLines() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.feed(Data("{\"a\":1}\n{\"b\"".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(splitter.feed(Data(":2}\n\n".utf8)), ["{\"b\":2}", ""])
        XCTAssertEqual(splitter.feed(Data("tail".utf8)), [])
        XCTAssertEqual(splitter.finish(), "tail")
        XCTAssertNil(splitter.finish())
    }

    func testLineSplitterHandlesMultibyteSplitAcrossChunks() {
        var splitter = LineSplitter()
        let bytes = Array("“hi”\n".utf8)
        XCTAssertEqual(splitter.feed(Data(bytes[0..<2])), [])
        XCTAssertEqual(splitter.feed(Data(bytes[2...])), ["“hi”"])
    }
}
