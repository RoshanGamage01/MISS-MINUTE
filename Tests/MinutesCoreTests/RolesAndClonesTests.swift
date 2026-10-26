import XCTest
@testable import MinutesCore

@MainActor
final class RoleTests: XCTestCase {
    private func registry(_ names: [String]) -> ToolRegistry {
        let registry = ToolRegistry()
        for name in names {
            registry.register(AgentTool(spec: .object(name, "x")) { _ in .ok("\(name) ran") })
        }
        registry.register(RoleTools.all(registry: registry))
        return registry
    }

    func testGeneralSeesEverythingAndRolesNarrow() {
        let tools = registry(["run_shell", "add_task", "get_calendar_events", "search_web", "play_youtube"])
        XCTAssertEqual(tools.specs.count, tools.allSpecs.count)

        tools.activeRole = .developer
        let names = tools.specs.map(\.name)
        XCTAssertTrue(names.contains("run_shell"))
        XCTAssertFalse(names.contains("get_calendar_events"))
        XCTAssertFalse(names.contains("play_youtube"))
        XCTAssertTrue(names.contains("switch_role"), "every role can switch back")

        tools.activeRole = .secretary
        XCTAssertTrue(tools.specs.map(\.name).contains("get_calendar_events"))
        XCTAssertFalse(tools.specs.map(\.name).contains("run_shell"))
    }

    func testFilteredToolIsRefusedWithAHint() async {
        let tools = registry(["run_shell", "add_task"])
        tools.activeRole = .researcher
        let outcome = await tools.execute(ToolCall(id: "1", name: "run_shell", arguments: [:]))
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.output.contains("switch_role"))
        let allowed = await tools.execute(ToolCall(id: "2", name: "add_task", arguments: [:]))
        XCTAssertFalse(allowed.isError)
    }

    func testSwitchRoleTool() async {
        let tools = registry(["run_shell", "add_task"])
        var changes: [Role] = []
        tools.onRoleChanged = { changes.append($0) }
        let outcome = await tools.execute(ToolCall(id: "1", name: "switch_role", arguments: ["role": "System Admin"]))
        XCTAssertFalse(outcome.isError, outcome.output)
        XCTAssertEqual(tools.activeRole, .systemAdmin)
        XCTAssertEqual(changes, [.systemAdmin])

        let bad = await tools.execute(ToolCall(id: "2", name: "switch_role", arguments: ["role": "astronaut"]))
        XCTAssertTrue(bad.isError)
        XCTAssertEqual(tools.activeRole, .systemAdmin)
    }

    func testRoleNames() {
        XCTAssertEqual(Role.named("dev"), .developer)
        XCTAssertEqual(Role.named("Secretary"), .secretary)
        XCTAssertEqual(Role.named("sysadmin"), .systemAdmin)
        XCTAssertEqual(Role.named("System-Admin"), .systemAdmin)
        XCTAssertNil(Role.named("pirate"))
    }

    func testRoleShapesPromptAndContext() {
        XCTAssertEqual(ChatService.systemPrompt("base", role: .general), "base")
        XCTAssertTrue(ChatService.systemPrompt("base", role: .developer).contains("Developer mode"))
        let context = AgentContext(role: .researcher).render()
        XCTAssertTrue(context.contains("Your role: 🔍 Researcher"))
        XCTAssertFalse(AgentContext().render().contains("Your role"))
    }

    func testChatSendsRoleFilteredTools() async {
        let tools = registry(["run_shell", "get_calendar_events"])
        let provider = ScriptedProvider([
            [
                .toolCall(ToolCall(id: "c1", name: "switch_role", arguments: ["role": "developer"])),
                .finished(stop: .toolUse, rawContent: nil)
            ],
            [.textDelta("Ready to code, sugar."), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let chat = ChatService(
            store: JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json")),
            tools: tools,
            providerFactory: { provider }
        )
        let replied = expectation(description: "reply")
        chat.onReply = { _ in replied.fulfill() }
        chat.send("let's write some code")
        await fulfillment(of: [replied], timeout: 5)

        XCTAssertTrue(provider.requests[0].tools.map(\.name).contains("get_calendar_events"))
        XCTAssertFalse(provider.requests[1].tools.map(\.name).contains("get_calendar_events"))
        XCTAssertTrue(provider.requests[1].systemPrompt.contains("Developer mode"))
    }

    func testPromptMentionsRolesAndClonesAndMigrates() {
        XCTAssertTrue(Persona.defaultPrompt.contains("switch_role"))
        XCTAssertTrue(Persona.defaultPrompt.contains("spawn_clone"))
        XCTAssertFalse(Persona.isLegacyDefault(Persona.defaultPrompt))
        let previous = "…- Don't narrate. No \"I'll now do X\" or play-by-play between steps…"
        XCTAssertTrue(Persona.isLegacyDefault(previous))
    }
}

@MainActor
final class CloneTests: XCTestCase {
    private func makeRegistry(log: @escaping (String) -> Void = { _ in }) -> ToolRegistry {
        let registry = ToolRegistry()
        for name in ["search_web", "read_webpage", "run_shell", "recall", "click", "add_task"] {
            registry.register(AgentTool(spec: .object(name, "x")) { _ in
                log(name)
                return .ok("\(name) result")
            })
        }
        return registry
    }

    func testCloneRunsWithItsToolsAndReportsBack() async throws {
        var ran: [String] = []
        let registry = makeRegistry { ran.append($0) }
        let provider = ScriptedProvider([
            [
                .toolCall(ToolCall(id: "1", name: "search_web", arguments: ["query": "flights"])),
                .toolCall(ToolCall(id: "2", name: "report_progress", arguments: ["note": "Found 3 fares"])),
                .finished(stop: .toolUse, rawContent: nil)
            ],
            [
                // Not in its toolset: refused, never run.
                .toolCall(ToolCall(id: "3", name: "add_task", arguments: ["title": "x"])),
                .finished(stop: .toolUse, rawContent: nil)
            ],
            [.textDelta("Cheapest fare: $212 on Delta."), .finished(stop: .endTurn, rawContent: nil)]
        ])
        let manager = CloneManager(registry: registry, providerFactory: { provider })
        var notes: [String] = []
        manager.onProgress = { _, note, _ in if let note { notes.append(note) } }
        let finished = expectation(description: "finished")
        var result: AgentClone?
        manager.onFinished = {
            result = $0
            finished.fulfill()
        }

        let clone = try manager.spawn(purpose: "Web-Scraper", task: "Find the cheapest flight", tools: ["search_web", "read_webpage"])
        XCTAssertEqual(clone.icon, "🔍")
        XCTAssertEqual(manager.active.count, 1)
        await fulfillment(of: [finished], timeout: 5)

        XCTAssertEqual(ran, ["search_web"])
        XCTAssertEqual(notes, ["Found 3 fares"])
        XCTAssertEqual(result?.status, .finished)
        XCTAssertEqual(result?.result, "Cheapest fare: $212 on Delta.")
        XCTAssertEqual(result?.steps, 3)
        XCTAssertTrue(manager.active.isEmpty)
        // It saw only its own tools plus the clone-only ones.
        XCTAssertEqual(Set(provider.requests[0].tools.map(\.name)), ["search_web", "read_webpage", "report_progress", "pause"])
        XCTAssertTrue(provider.requests[0].systemPrompt.contains("Web-Scraper"))
        XCTAssertTrue(CloneManager.followUpNote(for: try XCTUnwrap(result)).contains("$212"))
    }

    func testToolResolution() {
        let manager = CloneManager(registry: makeRegistry(), providerFactory: { ScriptedProvider([]) })
        let picked = manager.resolveTools(["searchWeb", "click", "teleport"])
        XCTAssertEqual(picked.tools, ["search_web"])
        XCTAssertTrue(picked.note?.contains("click") == true)
        XCTAssertEqual(manager.resolveTools([]).tools, ["search_web", "read_webpage", "run_shell", "recall"])
        XCTAssertEqual(Set(manager.resolveTools(["researcher"]).tools), ["search_web", "read_webpage", "add_task"])
    }

    func testLimitsAndCancel() throws {
        let manager = CloneManager(registry: makeRegistry(), providerFactory: { HangingProvider() })
        var finished: [AgentClone] = []
        manager.onFinished = { finished.append($0) }
        for index in 0..<CloneManager.maxActive {
            try manager.spawn(purpose: "Watcher \(index)", task: "watch", tools: [])
        }
        XCTAssertThrowsError(try manager.spawn(purpose: "One too many", task: "x", tools: []))

        XCTAssertEqual(manager.find("c2")?.purpose, "Watcher 1")
        XCTAssertEqual(manager.cancel(2)?.status, .cancelled)
        XCTAssertNil(manager.cancel(2), "already stopped")
        manager.cancelAll()
        XCTAssertTrue(manager.active.isEmpty)
        XCTAssertEqual(finished.count, CloneManager.maxActive)
    }

    func testCloneToolsAndPolicy() async {
        let registry = makeRegistry()
        let manager = CloneManager(registry: registry, providerFactory: { HangingProvider() })
        registry.register(CloneTools.all(manager: manager, initiative: { .user }))

        let spawned = await registry.execute(ToolCall(id: "1", name: "spawn_clone", arguments: [
            "purpose": "File-Watcher", "task": "Tell me when report.pdf appears", "tools": ["run_shell", "click"]
        ]))
        XCTAssertFalse(spawned.isError, spawned.output)
        XCTAssertTrue(spawned.output.contains("[c1]"))
        XCTAssertTrue(spawned.output.contains("click"), "mentions what it left out")
        XCTAssertEqual(manager.active.first?.tools, ["run_shell"])
        XCTAssertEqual(manager.active.first?.icon, "👀")

        let listed = await registry.execute(ToolCall(id: "2", name: "list_clones", arguments: [:]))
        XCTAssertTrue(listed.output.contains("File-Watcher"))
        XCTAssertTrue(AgentContext(clones: manager.clones).render().contains("Your clones:"))

        let stopped = await registry.execute(ToolCall(id: "3", name: "stop_clone", arguments: ["clone": "watcher"]))
        XCTAssertFalse(stopped.isError, stopped.output)
        XCTAssertTrue(manager.active.isEmpty)

        XCTAssertEqual(AutonomyPolicy.risk(of: ToolCall(id: "4", name: "spawn_clone", arguments: [:])), .reversible)
        XCTAssertEqual(AutonomyPolicy.risk(of: ToolCall(id: "5", name: "list_clones", arguments: [:])), .observe)
    }

    func testLabels() {
        var clone = AgentClone(id: 1, purpose: "Web-Scraper", task: "", tools: [], status: .running,
                               progress: "Searching the web…", steps: 1, startedAt: Date(), initiative: .user)
        XCTAssertEqual(clone.label, "🔍 Searching the web…")
        clone.status = .finished
        XCTAssertEqual(clone.label, "🔍 Web-Scraper done")
        XCTAssertEqual(AgentClone.icon(for: "Something else"), "⏱")
    }
}

/// A model that never answers (until cancelled), for clones that should stay running.
final class HangingProvider: ChatProvider, @unchecked Sendable {
    let kind: ProviderKind = .ollama
    func listModels() async throws -> [String] { [] }
    func streamTurn(_ request: AgentRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
