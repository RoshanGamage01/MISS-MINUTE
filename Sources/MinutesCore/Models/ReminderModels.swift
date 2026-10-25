import Foundation

public struct Reminder: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var fireAt: Date
    public var createdAt: Date
    public var isFired: Bool
    public var sourcePhrase: String?

    public init(
        id: UUID = UUID(),
        text: String,
        fireAt: Date,
        createdAt: Date = Date(),
        isFired: Bool = false,
        sourcePhrase: String? = nil
    ) {
        self.id = id
        self.text = text
        self.fireAt = fireAt
        self.createdAt = createdAt
        self.isFired = isFired
        self.sourcePhrase = sourcePhrase
    }

    public var shortID: String { String(id.uuidString.prefix(6)).lowercased() }
}

public struct ParsedReminder: Sendable, Equatable {
    public var text: String
    public var fireAt: Date
    public var matchedPhrase: String

    public init(text: String, fireAt: Date, matchedPhrase: String) {
        self.text = text
        self.fireAt = fireAt
        self.matchedPhrase = matchedPhrase
    }
}
