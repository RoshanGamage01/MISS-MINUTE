import XCTest
@testable import MinutesCore

@MainActor
final class MemoryGraphTests: XCTestCase {
    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    func testEntitiesAndKeywords() {
        XCTAssertEqual(MemoryGraph.entities(in: "User's sister Maya lives in Austin."), ["maya", "austin"])
        XCTAssertEqual(MemoryGraph.entities(in: "Maya's birthday is May 3."), ["maya"])
        XCTAssertTrue(MemoryGraph.keywords(in: "User drinks oat lattes every morning.").isSuperset(of: ["drink", "oat", "latte", "morning"]))
    }

    func testRelatedMemoriesLinkAutomatically() async {
        let store = MemoryStore(store: tempStore())
        let sister = await store.remember("User's sister Maya lives in Austin.", category: "person")
        let coffee = await store.remember("User drinks oat lattes.", category: "preference")
        let birthday = await store.remember("Maya's birthday is May 3.", category: "person")

        XCTAssertEqual(store.related(to: birthday.id).map(\.id), [sister.id])
        XCTAssertEqual(store.related(to: sister.id).map(\.id), [birthday.id], "links go both ways")
        XCTAssertTrue(store.related(to: coffee.id).isEmpty)

        await store.forget(id: sister.id)
        XCTAssertTrue(store.related(to: birthday.id).isEmpty, "forgetting cleans up links")
    }

    func testContextPullsRelatedMemoriesForTheMessage() async {
        let store = MemoryStore(store: tempStore())
        await store.remember("User's sister Maya lives in Austin.", category: "person")
        await store.remember("Maya's birthday is May 3.", category: "person")
        for i in 0..<5 { await store.remember("Unrelated fact number \(i) about gardening tools.") }

        let lines = store.contextLines(query: "what should I get Maya?", limit: 4)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("Maya"))
        XCTAssertTrue(lines[1].contains("related:") && lines[1].contains("Maya"), "the linked fact comes along: \(lines)")
        // Without a query: most recent first, as before.
        XCTAssertTrue(store.contextLines(limit: 1)[0].contains("number 4"))
    }

    func testSearchSpreadsToLinkedMemories() async {
        let store = MemoryStore(store: tempStore())
        let wife = await store.remember("User's wife is Priya.", category: "person")
        let anniversary = await store.remember("Their wedding anniversary is June 4.", category: "other")
        await store.link(wife.id, anniversary.id)
        let results = store.search("Priya")
        XCTAssertEqual(results.map(\.id), [wife.id, anniversary.id])
    }

    func testCuratorLinksByIdOrNewFactText() async {
        let text = #"{"add":[{"fact":"User is training for the Austin marathon.","category":"goal"}],"link":[["ab12cd","User is training for the Austin marathon."]]}"#
        let edits = MemoryCurator.parse(text)
        XCTAssertEqual(edits.last, .link(ref: "ab12cd", to: "User is training for the Austin marathon."))

        let store = MemoryStore(store: tempStore())
        let run = await store.remember("User runs every morning at 6.", category: "routine")
        let curator = MemoryCurator(store: store)
        let changes = await curator.apply([
            .link(ref: run.shortID, to: "User is training for the Austin marathon."),
            .add(fact: "User is training for the Austin marathon.", category: "goal")
        ])
        XCTAssertEqual(changes.count, 2, "the add runs before the link that refers to it: \(changes)")
        XCTAssertEqual(store.related(to: run.id).first?.fact, "User is training for the Austin marathon.")
    }

    func testOldMemoryFilesStillLoad() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","fact":"User prefers tea.","category":"preference","createdAt":0}]"#
        let items = try JSONDecoder().decode([MemoryItem].self, from: Data(json.utf8))
        XCTAssertNil(items[0].links)
    }
}
