import Foundation
import os

/// Measures how long it takes from the end of the user's request to the first sound of Miss Minute's reply,
/// stage by stage, and logs one summary line per turn:
///
///     log stream --predicate 'subsystem == "com.minutes.app" AND category == "latency"'
@MainActor
public final class LatencyTrace {
    public static let shared = LatencyTrace()

    public enum Stage: String, CaseIterable, Sendable {
        /// The user stopped talking (last change in the live transcript).
        case speechEnded
        /// Speech recognition handed over the final transcript.
        case sttFinal
        /// The message entered the chat service.
        case send
        /// The context block was built and the request is about to go out.
        case requestSent
        /// The model's first text token arrived.
        case firstToken
        /// The model started a tool call (before any of it runs).
        case toolStarted
        /// The first chunk of text was handed to the voice.
        case firstChunk
        /// The voice engine started rendering it.
        case ttsRequest
        /// Audio started playing.
        case firstAudio
    }

    public struct Report: Sendable, Equatable {
        public var origin: String
        public var engine: String
        /// Milliseconds from the trace's start, in the order the stages happened.
        public var marks: [(stage: Stage, ms: Int)]

        public static func == (lhs: Report, rhs: Report) -> Bool {
            lhs.origin == rhs.origin && lhs.engine == rhs.engine
                && lhs.marks.map(\.stage) == rhs.marks.map(\.stage) && lhs.marks.map(\.ms) == rhs.marks.map(\.ms)
        }

        public var totalMs: Int { marks.last?.ms ?? 0 }

        public func ms(_ stage: Stage) -> Int? { marks.first { $0.stage == stage }?.ms }

        /// "latency[spoken] total 1234ms · sttFinal +800 · send +1 · …"
        public var line: String {
            var parts: [String] = []
            var previous = 0
            for mark in marks {
                parts.append("\(mark.stage.rawValue) +\(mark.ms - previous)")
                previous = mark.ms
            }
            return "latency[\(origin)] total \(totalMs)ms via \(engine) · " + parts.joined(separator: " · ")
        }
    }

    private static let logger = Logger(subsystem: "com.minutes.app", category: "latency")

    /// Where reports go (os log + stdout by default).
    public var sink: (Report) -> Void = { report in
        LatencyTrace.logger.notice("\(report.line, privacy: .public)")
        print("⏱ " + report.line)
    }
    public private(set) var lastReport: Report?
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var start: TimeInterval?
    private var origin = ""
    private var marks: [(stage: Stage, at: TimeInterval)] = []

    public init() {}

    public var isActive: Bool { start != nil }

    /// Starts timing a turn. `at` lets voice input backdate the start to when the user stopped speaking.
    public func begin(origin: String, at time: TimeInterval? = nil) {
        start = time ?? now()
        self.origin = origin
        marks = []
    }

    /// Records a stage the first time it happens in this turn.
    public func mark(_ stage: Stage, at time: TimeInterval? = nil) {
        guard start != nil, !marks.contains(where: { $0.stage == stage }) else { return }
        marks.append((stage, time ?? now()))
        // An instant acknowledgement can play before the model answers; report once both are known.
        if stage == .firstToken || stage == .toolStarted { emitIfReady() }
    }

    public func has(_ stage: Stage) -> Bool { marks.contains { $0.stage == stage } }

    /// Audio is playing: record it, and report as soon as the model's first output is known too.
    public func finish(engine: String) {
        guard start != nil, !has(.firstAudio) else { return }
        self.engine = engine
        mark(.firstAudio)
        emitIfReady()
    }

    /// The turn is over: report whatever was measured (if any audio played).
    public func turnEnded() {
        guard start != nil else { return }
        // No audio yet (the text can finish before the voice starts): keep waiting for it; the next turn's
        // begin() discards it if speech never comes.
        if has(.firstAudio) { emitIfReady(force: true) }
    }

    private var engine = ""

    private func emitIfReady(force: Bool = false) {
        guard let start, has(.firstAudio), force || has(.firstToken) || has(.toolStarted) else { return }
        let report = Report(
            origin: origin,
            engine: self.engine,
            marks: marks.sorted { $0.at < $1.at }.map { ($0.stage, Int((($0.at - start) * 1000).rounded())) }
        )
        self.start = nil
        marks = []
        lastReport = report
        sink(report)
    }

    /// Stops timing without a report (the turn was cancelled or produced no speech).
    public func cancel() {
        start = nil
        marks = []
    }
}
