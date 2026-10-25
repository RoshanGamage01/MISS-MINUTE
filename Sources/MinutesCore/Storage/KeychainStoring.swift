import Foundation

public enum KeychainError: Error, LocalizedError, Equatable {
    case unexpectedStatus(Int32)
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status))"
        case .encodingFailed:
            return "Could not encode secret for Keychain"
        case .decodingFailed:
            return "Could not decode secret from Keychain"
        }
    }
}

/// Abstraction over the macOS Keychain so provider logic stays unit-testable.
public protocol KeychainStoring: Sendable {
    func setSecret(_ value: String, account: String) throws
    func getSecret(account: String) throws -> String?
    func deleteSecret(account: String) throws
}

/// Thread-safe in-memory keychain for unit tests.
public final class InMemoryKeychainBox: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func setSecret(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = value
    }

    public func getSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}

public struct KeychainAPIKeyProvider: APIKeyProviding, Sendable {
    public let keychain: any KeychainStoring

    public init(keychain: any KeychainStoring) {
        self.keychain = keychain
    }

    public func apiKey(for kind: ProviderKind) throws -> String? {
        try keychain.getSecret(account: kind.keychainAccount)
    }

    public func setAPIKey(_ value: String?, for kind: ProviderKind) throws {
        let account = kind.keychainAccount
        if let value, !value.isEmpty {
            try keychain.setSecret(value, account: account)
        } else {
            try keychain.deleteSecret(account: account)
        }
    }
}

/// Keychain accounts for secrets that aren't chat-provider keys.
public enum SecretAccount {
    public static let elevenLabs = "minutes.voice.elevenlabs.apiKey"
}
