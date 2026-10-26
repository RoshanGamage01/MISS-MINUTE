import Combine
import Foundation

/// One line of her inner monologue: what she noticed, weighed, decided, and did on her own.
public struct Thought: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Something she noticed about the Mac or the user's day.
        case noticed
        /// An option she weighed, and why she did or didn't take it.
        case considered
        /// What she chose to do.
        case decided
        /// A step she took on her own.
        case acted
        /// Goal progress.
        case progress
        /// The policy stopped her, or she held back.
        case heldBack
    }

    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), at: Date = Date(), kind: Kind, text: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.text = text
    }
}

/// Keeps her recent thoughts for the Mind tab, and appends each to a plain-text log for later review.
@MainActor
public final class ThoughtLog: ObservableObject {
    @Published public private(set) var thoughts: [Thought] = []

    public static let limit = 300
    private let store: JSONFileStore<[Thought]>
    private let logURL: URL?
    private var saveTask: Task<Void, Never>?

    public init(store: JSONFileStore<[Thought]> = JSONFileStore(url: MinutesPaths.thoughtsURL), logURL: URL? = MinutesPaths.thoughtsLogURL) {
        self.store = store
        self.logURL = logURL
    }

    public func load() async {
        thoughts = (try? await store.load(default: [])) ?? []
    }

    /// Records a thought. Repeats of the latest line within a few minutes are dropped so the stream stays readable.
    public func add(_ kind: Thought.Kind, _ text: String, at now: Date = Date()) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let last = thoughts.last, last.kind == kind, last.text == text, now.timeIntervalSince(last.at) < 10 * 60 { return }
        thoughts.append(Thought(at: now, kind: kind, text: text))
        if thoughts.count > Self.limit { thoughts.removeFirst(thoughts.count - Self.limit) }
        appendToLog(Thought(at: now, kind: kind, text: text))
        scheduleSave()
    }

    public func recent(_ count: Int) -> [Thought] { Array(thoughts.suffix(count)) }

    public func clear() {
        thoughts.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = thoughts
        saveTask = Task { [store] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            try? await store.save(snapshot)
        }
    }

    private func appendToLog(_ thought: Thought) {
        guard let logURL else { return }
        let line = Self.logLine(thought) + "\n"
        let manager = FileManager.default
        try? manager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    public static func logLine(_ thought: Thought) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return "\(formatter.string(from: thought.at)) [\(thought.kind.rawValue)] \(thought.text)"
    }
}
