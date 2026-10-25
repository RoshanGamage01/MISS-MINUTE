import XCTest
@testable import MinutesCore

final class ProviderFactoryTests: XCTestCase {
    func testMissingKeyThrowsForCloudProviders() {
        let keys = KeychainAPIKeyProvider(keychain: InMemoryKeychainBox())
        let factory = ChatProviderFactory(keyProvider: keys)

        XCTAssertThrowsError(try factory.makeProvider(for: .openAI)) { error in
            XCTAssertEqual(error as? ChatProviderError, .missingAPIKey)
        }
        XCTAssertThrowsError(try factory.makeProvider(for: .anthropic))
        XCTAssertThrowsError(try factory.makeProvider(for: .xAI))
    }

    func testOllamaDoesNotRequireKey() throws {
        let keys = KeychainAPIKeyProvider(keychain: InMemoryKeychainBox())
        let factory = ChatProviderFactory(keyProvider: keys)
        let provider = try factory.makeProvider(for: .ollama)
        XCTAssertEqual(provider.kind, .ollama)
    }

    func testOpenAIProviderCreatedWithKey() throws {
        let box = InMemoryKeychainBox()
        try box.setSecret("sk-test", account: ProviderKind.openAI.keychainAccount)
        let keys = KeychainAPIKeyProvider(keychain: box)
        let factory = ChatProviderFactory(keyProvider: keys)
        let provider = try factory.makeProvider(for: .openAI)
        XCTAssertEqual(provider.kind, .openAI)
    }

    func testKeychainRoundTrip() throws {
        let box = InMemoryKeychainBox()
        let keys = KeychainAPIKeyProvider(keychain: box)
        try keys.setAPIKey("secret-anthropic", for: .anthropic)
        XCTAssertEqual(try keys.apiKey(for: .anthropic), "secret-anthropic")
        try keys.setAPIKey(nil, for: .anthropic)
        XCTAssertNil(try keys.apiKey(for: .anthropic))
    }

    func testProviderKindDefaults() {
        XCTAssertTrue(ProviderKind.openAI.requiresAPIKey)
        XCTAssertFalse(ProviderKind.ollama.requiresAPIKey)
        XCTAssertEqual(ProviderKind.xAI.defaultModel, "grok-2-latest")
    }
}
