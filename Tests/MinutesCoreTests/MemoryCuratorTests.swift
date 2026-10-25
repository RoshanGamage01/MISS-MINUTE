import XCTest
@testable import MinutesCore

@MainActor
final class MemoryCuratorTests: XCTestCase {
    private func tempStore<T>() -> JSONFileStore<T> {
        JSONFileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString).json"))
    }

    func testGateSkipsTrivialTurns() {
        XCTAssertFalse(MemoryCurator.mightBeMemorable("thanks!"))
        XCTAssertFalse(MemoryCurator.mightBeMemorable("what time is it"))
        XCTAssertTrue(MemoryCurator.mightBeMemorable("My sister Maya just moved to Austin"))
        XCTAssertTrue(MemoryCurator.mightBeMemorable("I’m allergic to peanuts, by the way"))
    }

    func testParsesFencedJSON() {
        let text = """
        ```json
        {"add":[{"fact":"User's sister Maya lives in Austin.","category":"person"}],"update":[{"id":"AB12CD","fact":"User drinks oat lattes."}],"remove":["ff00aa"]}
        ```
        """
        XCTAssertEqual(MemoryCurator.parse(text), [
            .add(fact: "User's sister Maya lives in Austin.", category: "person"),
            .update(ref: "ab12cd", fact: "User drinks oat lattes."),
            .remove(ref: "ff00aa")
        ])
        XCTAssertEqual(MemoryCurator.parse("nothing to note"), [])
    }

    func testAppliesEditsToStore() async {
        let store = MemoryStore(store: tempStore())
        let old = await store.remember("User lives in Denver.", category: "other")
        let stale = await store.remember("User is learning guitar.")
        let curator = MemoryCurator(store: store)

        let changes = await curator.apply([
            .update(ref: old.shortID, fact: "User lives in Austin."),
            .remove(ref: stale.shortID),
            .add(fact: "User prefers tea.", category: "preference"),
            .add(fact: "User prefers tea.", category: "preference")
        ])
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(store.items.map(\.fact), ["User lives in Austin.", "User prefers tea."])
    }
}
