import Foundation

public actor JSONFileStore<Value: Codable & Sendable> {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load(default defaultValue: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}

public enum MinutesPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Minutes", isDirectory: true)
    }

    public static var settingsURL: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }

    public static var conversationURL: URL {
        applicationSupport.appendingPathComponent("conversation.json")
    }

    public static var remindersURL: URL {
        applicationSupport.appendingPathComponent("reminders.json")
    }

    public static var tasksURL: URL {
        applicationSupport.appendingPathComponent("tasks.json")
    }

    public static var memoryURL: URL {
        applicationSupport.appendingPathComponent("memory.json")
    }

    public static var usageURL: URL {
        applicationSupport.appendingPathComponent("usage.json")
    }
}
