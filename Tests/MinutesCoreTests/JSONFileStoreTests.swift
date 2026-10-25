import XCTest
@testable import MinutesCore

final class JSONFileStoreTests: XCTestCase {
    func testRoundTripConversation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONFileStore<Conversation>(url: url)
        var conversation = Conversation(title: "Test")
        conversation.messages.append(ChatMessage(role: .user, content: "Hello"))
        try await store.save(conversation)

        let loaded = try await store.load(default: Conversation())
        XCTAssertEqual(loaded.title, "Test")
        XCTAssertEqual(loaded.messages.count, 1)
        XCTAssertEqual(loaded.messages.first?.content, "Hello")
    }
}
