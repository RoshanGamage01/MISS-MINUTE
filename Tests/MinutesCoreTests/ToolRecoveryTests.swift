import XCTest
@testable import MinutesCore

@MainActor
final class ToolRecoveryTests: XCTestCase {
    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    func testFallsBackToTheNextApproach() async throws {
        var tried: [String] = []
        let outcome = try await ToolRecovery.firstSuccess("open Code", [
            .init("first") { tried.append("first"); throw ToolError("not found") },
            .init("second") { tried.append("second"); return .failure("refused") },
            .init("third") { tried.append("third"); return .ok("Opened Code.") },
            .init("fourth") { tried.append("fourth"); return .ok("unused") }
        ])
        XCTAssertEqual(tried, ["first", "second", "third"])
        XCTAssertTrue(outcome.output.hasPrefix("Opened Code."))
        XCTAssertTrue(outcome.output.contains("used third instead"))
    }

    func testReportsEveryApproachWhenAllFail() async {
        do {
            _ = try await ToolRecovery.firstSuccess("open Foo", [
                .init("open -a") { throw ToolError("not found") },
                .init("Spotlight") { throw ToolError("nothing") }
            ])
            XCTFail("should throw")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("open -a: not found") && message.contains("Spotlight: nothing"), message)
        }
    }

    func testResolvesMisnamedTools() {
        let known = ["open_app", "open_url", "get_calendar_events", "add_task", "list_tasks"]
        XCTAssertEqual(ToolRecovery.resolveName("OpenApp", among: known), "open_app")
        XCTAssertEqual(ToolRecovery.resolveName("open-app", among: known), "open_app")
        XCTAssertEqual(ToolRecovery.resolveName("open_application", among: known), "open_app")
        XCTAssertEqual(ToolRecovery.resolveName("launch_app", among: known), "open_app")
        XCTAssertEqual(ToolRecovery.resolveName("get_calendar", among: known), "get_calendar_events")
        XCTAssertNil(ToolRecovery.resolveName("send_email", among: known))
    }

    func testRepairsArgumentKeys() {
        let spec = ToolSpec.object("open_url", "x", properties: ["url": ["type": "string"]], required: ["url"])
        XCTAssertEqual(ToolRecovery.repairArguments(["link": "example.com"], spec: spec), ["url": "example.com"])
        XCTAssertEqual(ToolRecovery.repairArguments(["page": "example.com"], spec: spec), ["url": "example.com"], "a lone unknown key")
        XCTAssertNil(ToolRecovery.repairArguments(["url": "example.com"], spec: spec), "nothing to repair")
    }

    func testRegistryHealsNameAndArguments() async {
        let registry = ToolRegistry()
        var opened: String?
        registry.register(AgentTool(spec: .object("open_app", "open", properties: ["name": ["type": "string"]], required: ["name"])) { args in
            opened = try args.requiredString("name")
            return .ok("Opened")
        })
        let outcome = await registry.execute(ToolCall(id: "1", name: "openApplication", arguments: ["app": "Notes"]))
        XCTAssertFalse(outcome.isError, outcome.output)
        XCTAssertEqual(opened, "Notes")
        let unknown = await registry.execute(ToolCall(id: "2", name: "fly_to_moon", arguments: [:]))
        XCTAssertTrue(unknown.isError && unknown.output.contains("Available: open_app"))
    }

    func testRegistryRetriesTransientFailuresOnlyForSafeTools() async {
        let registry = ToolRegistry()
        var reads = 0, clicks = 0
        registry.register(AgentTool(spec: .object("read_webpage", "read")) { _ in
            reads += 1
            if reads == 1 { throw ToolError("The request timed out.") }
            return .ok("page")
        })
        registry.register(AgentTool(spec: .object("click", "click")) { _ in
            clicks += 1
            throw ToolError("The request timed out.")
        })
        let read = await registry.execute(ToolCall(id: "1", name: "read_webpage", arguments: [:]))
        XCTAssertEqual(read.output, "page")
        XCTAssertEqual(reads, 2)
        _ = await registry.execute(ToolCall(id: "2", name: "click", arguments: [:]))
        XCTAssertEqual(clicks, 1, "actions with side effects are never repeated automatically")
    }

    func testBestMatchAndLenientNumbers() {
        let titles = ["Buy milk", "Send invoice to Acme", "Book dentist appointment"]
        XCTAssertEqual(ToolRecovery.bestMatch("the acme invoice", in: titles, text: { $0 }), "Send invoice to Acme")
        XCTAssertEqual(ToolRecovery.bestMatch("dentist", in: titles, text: { $0 }), "Book dentist appointment")
        XCTAssertNil(ToolRecovery.bestMatch("walk the dog", in: titles, text: { $0 }))

        let args: JSONValue = ["a": "15", "b": "1.5 hours", "c": 20, "d": "90 seconds", "e": "soon"]
        XCTAssertEqual(args.lenientNumber("a", minutes: true), 15)
        XCTAssertEqual(args.lenientNumber("b", minutes: true), 90)
        XCTAssertEqual(args.lenientNumber("c", minutes: true), 20)
        XCTAssertEqual(args.lenientNumber("d", minutes: true), 1.5)
        XCTAssertNil(args.lenientNumber("e", minutes: true))
    }

    func testCoreToolsRecoverFromLooseReferences() async {
        let tasks = TaskStore(store: tempStore())
        let reminders = ReminderStore(store: tempStore())
        let registry = ToolRegistry()
        registry.register(CoreTools.all(tasks: tasks, reminders: reminders, memory: MemoryStore(store: tempStore())))
        await tasks.add(title: "Send invoice to Acme", notes: nil, dueAt: nil, priority: .normal)

        let done = await registry.execute(ToolCall(id: "1", name: "complete_task", arguments: ["task": "the acme invoice"]))
        XCTAssertFalse(done.isError, done.output)
        XCTAssertTrue(tasks.openTasks.isEmpty)

        let miss = await registry.execute(ToolCall(id: "2", name: "delete_task", arguments: ["task": "the acme invoice"]))
        XCTAssertTrue(miss.isError, "deleting never guesses at a fuzzy match")

        let timer = await registry.execute(ToolCall(id: "3", name: "start_timer", arguments: ["minutes": "25 min", "label": "focus"]))
        XCTAssertFalse(timer.isError, timer.output)

        let reminder = await registry.execute(ToolCall(id: "4", name: "set_reminder", arguments: ["text": "stretch", "at": "in 2 hours"]))
        XCTAssertFalse(reminder.isError, reminder.output)
    }
}
