import XCTest
@testable import MinutesCore

/// Plays back scripted model responses, one per call.
final class ScriptedProvider: ChatProvider, @unchecked Sendable {
    let kind: ProviderKind = .ollama
    private let lock = NSLock()
    private var scripts: [[ProviderEvent]]
    private(set) var requests: [AgentRequest] = []

    init(_ scripts: [[ProviderEvent]]) {
        self.scripts = scripts
    }

    func listModels() async throws -> [String] { ["scripted"] }

    func streamTurn(_ request: AgentRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = scripts.isEmpty ? [.finished(stop: .endTurn, rawContent: nil)] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor
final class AgentLoopTests: XCTestCase {
    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    func testToolCallThenReply() async throws {
        let tasks = TaskStore(store: tempStore())
        let reminders = ReminderStore(store: tempStore())
        let memory = MemoryStore(store: tempStore())
        let registry = ToolRegistry()
        registry.register(CoreTools.all(tasks: tasks, reminders: reminders, memory: memory))

        let provider = ScriptedProvider([
            [
                .textDelta("Tracking that now."),
                .toolCall(ToolCall(id: "c1", name: "add_task", arguments: ["title": "Send invoice", "due": "2030-01-03T17:00", "priority": "high"])),
                .finished(stop: .toolUse, rawContent: nil)
            ],
            [
                .textDelta("All set, sugar — invoice is on the timeline."),
                .finished(stop: .endTurn, rawContent: nil)
            ]
        ])

        var spoken: [(String, Bool)] = []
        let chat = ChatService(
            store: tempStore(),
            tools: registry,
            contextProvider: { mode in "ctx \(mode)" },
            providerFactory: { provider }
        )
        chat.onSpeak = { spoken.append(($0, $1)) }
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }

        chat.send("I need to send the invoice by Jan 3", inputMode: "spoken")
        await fulfillment(of: [replied], timeout: 5)

        XCTAssertEqual(tasks.openTasks.first?.title, "Send invoice")
        XCTAssertEqual(tasks.openTasks.first?.priority, .high)
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertFalse(provider.requests[0].tools.isEmpty)

        let roles = chat.conversation.messages.map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(chat.conversation.messages[0].contextNote, "ctx spoken")
        XCTAssertEqual(chat.conversation.messages[2].displaySummary?.hasPrefix("Added task: Send invoice"), true)
        XCTAssertEqual(spoken.map { $0.1 }, [false, true], "first part interrupts, later parts queue")
        XCTAssertFalse(chat.isStreaming)
    }

    func testAnnouncementDuringTurnIsDeferred() async throws {
        let provider = ScriptedProvider([[.textDelta("Done."), .finished(stop: .endTurn, rawContent: nil)]])
        let chat = ChatService(store: tempStore(), providerFactory: { provider })
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("hi")
        chat.announce("Reminder!", speak: false)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(chat.conversation.messages.map(\.content), ["hi", "Done.", "Reminder!"])
    }

    func testInvalidJSONArgumentsReturnError() async {
        let registry = ToolRegistry()
        registry.register(AgentTool(spec: .object("noop", "x")) { _ in .ok("ran") })
        let outcome = await registry.execute(ToolCall(id: "1", name: "noop", arguments: ["__invalid_json": "{"]))
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.output.hasPrefix("INVALID_JSON"))
    }
}

@MainActor
final class CoreToolTests: XCTestCase {
    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    func testTaskLifecycle() async {
        let tasks = TaskStore(store: tempStore())
        let registry = ToolRegistry()
        registry.register(CoreTools.all(tasks: tasks, reminders: ReminderStore(store: tempStore()), memory: MemoryStore(store: tempStore())))

        _ = await registry.execute(ToolCall(id: "1", name: "add_task", arguments: ["title": "Water the plants"]))
        let list = await registry.execute(ToolCall(id: "2", name: "list_tasks", arguments: [:]))
        XCTAssertTrue(list.output.contains("Water the plants"))

        let done = await registry.execute(ToolCall(id: "3", name: "complete_task", arguments: ["task": "plants"]))
        XCTAssertFalse(done.isError)
        XCTAssertTrue(tasks.openTasks.isEmpty)

        let missing = await registry.execute(ToolCall(id: "4", name: "complete_task", arguments: ["task": "nope"]))
        XCTAssertTrue(missing.isError)
    }

    func testReminderAndMemoryTools() async {
        let reminders = ReminderStore(store: tempStore())
        let memory = MemoryStore(store: tempStore())
        let registry = ToolRegistry()
        registry.register(CoreTools.all(tasks: TaskStore(store: tempStore()), reminders: reminders, memory: memory))

        let set = await registry.execute(ToolCall(id: "1", name: "set_reminder", arguments: ["text": "Stretch", "in_minutes": 20]))
        XCTAssertFalse(set.isError)
        XCTAssertEqual(reminders.upcoming.count, 1)

        let past = await registry.execute(ToolCall(id: "2", name: "set_reminder", arguments: ["text": "x", "at": "2001-01-01T10:00"]))
        XCTAssertTrue(past.isError)

        _ = await registry.execute(ToolCall(id: "3", name: "remember", arguments: ["fact": "User takes coffee black.", "category": "preference"]))
        let recall = await registry.execute(ToolCall(id: "4", name: "recall", arguments: ["query": "coffee"]))
        XCTAssertTrue(recall.output.contains("coffee black"))
        XCTAssertEqual(memory.contextLines(), ["- User takes coffee black."])
    }

    func testToolDatesParsing() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = ToolDates.parse("2026-10-25T15:30", calendar: cal)
        XCTAssertEqual(date.map { cal.component(.hour, from: $0) }, 15)
        let dayOnly = ToolDates.parse("2026-10-27", calendar: cal)
        XCTAssertEqual(dayOnly.map { cal.component(.hour, from: $0) }, 9)
        XCTAssertNotNil(ToolDates.parse("2026-10-25T15:30:00Z"))
        XCTAssertNil(ToolDates.parse("whenever"))
    }
}

@MainActor
final class ContextAndUsageTests: XCTestCase {
    func testContextRenderIncludesTasksAndMemories() {
        let now = Date()
        let overdue = TrackedTask(title: "File taxes", dueAt: now.addingTimeInterval(-3_600), priority: .high)
        let text = AgentContext(
            now: now,
            userName: "Sam",
            frontmostApp: "Xcode",
            minutesInApp: 42,
            openTasks: [overdue],
            memories: ["- Likes tea"],
            inputMode: "spoken"
        ).render()
        XCTAssertTrue(text.contains("User's name: Sam."))
        XCTAssertTrue(text.contains("OVERDUE"))
        XCTAssertTrue(text.contains("Xcode (42m so far)"))
        XCTAssertTrue(text.contains("- Likes tea"))
        XCTAssertTrue(text.contains("spoken"))
    }

    func testUsageTrackerAccumulatesFocusTime() {
        let tracker = UsageTracker(store: nil)
        let start = Date()
        tracker.appDidActivate("Xcode", at: start)
        tracker.appDidActivate("Safari", at: start.addingTimeInterval(30 * 60))
        let today = tracker.today(at: start.addingTimeInterval(40 * 60))
        XCTAssertEqual(today.first?.app, "Xcode")
        XCTAssertEqual(today.first?.minutes, 30)
        XCTAssertEqual(tracker.continuousActiveMinutes(at: start.addingTimeInterval(40 * 60)), 40)
        tracker.userWentIdle(idleSince: start.addingTimeInterval(40 * 60))
        XCTAssertEqual(tracker.continuousActiveMinutes(), 0)
    }

    func testBriefingMentionsOverdueWork() {
        let now = Date()
        let text = Briefing.compose(
            tasks: [TrackedTask(title: "Call the bank", dueAt: now.addingTimeInterval(-600))],
            reminders: [],
            calendarLines: [],
            name: "Sam",
            now: now
        )
        XCTAssertTrue(text.contains("Sam"))
        XCTAssertTrue(text.contains("Call the bank"))
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x"], "c": .null]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        XCTAssertEqual(JSONValue(any: value.anyValue), value)
        XCTAssertEqual(JSONValue.parse(#"{"n": 2.5}"#)?["n"]?.doubleValue, 2.5)
    }
}
