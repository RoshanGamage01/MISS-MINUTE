import AVFoundation
import Combine
import MinutesCore
import os

/// Speaks Miss Minute's lines and drives her lip-sync.
///
/// Engines: paid cloud voices (ElevenLabs, OpenAI) when keys exist, a free local neural server (Kokoro),
/// the Mac's system voice through `say` (which can be a Siri voice), and AVSpeechSynthesizer as the last
/// resort. Text is spoken chunk by chunk; the next chunk's audio renders while the current one plays.
///
/// Latency: neural voices stream raw PCM and start playing on the first ~50 ms of audio. `say` can't stream,
/// so a line whose file isn't rendered yet is spoken live instead of waiting for the render. Connections,
/// the audio engine, and voices are warmed up ahead of time (`prewarm`).
@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechManager()
    /// `log stream --predicate 'subsystem == "com.minutes.app" AND category == "speech"'`
    private static let log = Logger(subsystem: "com.minutes.app", category: "speech")

    @Published private(set) var isSpeaking = false
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var lastEngineError: String?
    /// Which engine actually spoke last ("ElevenLabs", "OpenAI", "macOS").
    @Published private(set) var activeEngineName = "macOS"

    /// Fires when a spoken line finishes and nothing else is queued, with the full text that was said.
    var onFinishedSpeaking: ((String) -> Void)?
    /// The user's mood right now: calmer delivery when they're stressed, brighter when they're winning.
    var toneProvider: () -> MoodTone = { .steady }

    /// Delivery direction for OpenAI's instructable TTS.
    static let neuralStyle = """
    Speak like a real person in a relaxed, natural conversation — not an announcer or narrator. \
    Character: a bright, warm, witty young woman with a light Southern American drawl, a little sassy and very \
    friendly, smiling as she talks. Vary pitch and pacing naturally, with small breaths and playful emphasis.
    """

    private enum Engine: Equatable {
        case elevenLabs(key: String)
        case openAI(key: String)
        case local(url: String, voice: String)
        case appleSystem
        case system

        var name: String {
            switch self {
            case .elevenLabs: return "ElevenLabs"
            case .openAI: return "OpenAI"
            case .local: return "Kokoro (local)"
            case .appleSystem: return "Mac system voice"
            case .system: return "macOS voice"
            }
        }

        /// Key for failure back-off.
        var kind: String {
            switch self {
            case .elevenLabs: return "eleven"
            case .openAI: return "openai"
            case .local: return "local"
            case .appleSystem: return "say"
            case .system: return "system"
            }
        }
    }

    private enum Audio {
        /// A whole rendered file (`say`); `box` fills in when it's ready.
        case file(Task<Data, Error>, RenderBox)
        /// PCM arriving from a streaming endpoint.
        case stream(AsyncThrowingStream<Data, Error>, producer: Task<Void, Never>)

        func cancel() {
            switch self {
            case .file(let task, _): task.cancel()
            case .stream(_, let producer): producer.cancel()
            }
        }
    }

    private final class RenderBox {
        var data: Data?
    }

    private struct Line {
        var text: String
        var previous: String?
        var next: String?
        var engine: Engine
        var prosody: Prosody = .neutral
        var audio: Audio?
    }

    /// Counts lines across a reply so prosody varies from one to the next.
    private var lineCounter = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private let streamPlayer = StreamingAudioPlayer()
    /// `say` speaking live (its line wasn't rendered in time). Holding the wrapper keeps its exit callback alive;
    /// without it the "finished" signal was lost and the queue stalled after the first line.
    private var liveSay: SayProcess?
    private var lastPrewarm: [String: Date] = [:]
    private var queue: [Line] = []
    private var spokenThisRun: [String] = []
    private var generation = 0
    private var settingsProvider: () -> AppSettings = { .default }
    private var secretProvider: (String) -> String? = { _ in nil }
    private var backoffUntil: [String: Date] = [:]
    private var autoVoiceID: String?
    /// Last probe result for the local neural server.
    @Published private(set) var localServerReachable = false
    private var lastLocalProbe: Date = .distantPast

    // Lip-sync state
    private var lastWordAt: TimeInterval = 0
    private var lastWordLength = 4

    private override init() {
        super.init()
        synthesizer.delegate = self
        refreshVoices()
    }

    /// `secret` returns a stored key for a Keychain account (e.g. OpenAI or ElevenLabs).
    func configure(settingsProvider: @escaping () -> AppSettings, secret: @escaping (String) -> String?) {
        self.settingsProvider = settingsProvider
        self.secretProvider = secret
        refreshVoices()
        probeLocalServer(force: true)
        prewarm(launch: true)
        // Refresh the standby voice process while idle so it's never stale when she needs it.
        standbyRefresh = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSpeaking, self.settingsProvider().voiceEnabled,
                      self.resolveEngine(self.settingsProvider()) == .appleSystem else { return }
                let settings = self.settingsProvider()
                self.spawnStandbySay(wordsPerMinute: Self.sayWordsPerMinute(settings.speechRate), voice: settings.sayVoice)
            }
        }
    }

    private var standbyRefresh: Timer?

    /// Gets the voice ready to speak instantly: starts the audio engine, opens the TTS connection, and loads
    /// the voice. Cheap and throttled; call it at launch and whenever a reply is likely to follow soon
    /// (the mic opened, a message was sent).
    func prewarm(launch: Bool = false) {
        let settings = settingsProvider()
        guard settings.voiceEnabled else { return }
        streamPlayer.prewarm()
        let engine = resolveEngine(settings)
        let throttle: TimeInterval = engine == .appleSystem ? 60 : 20
        guard launch || Date().timeIntervalSince(lastPrewarm[engine.kind] ?? .distantPast) > throttle else { return }
        lastPrewarm[engine.kind] = Date()
        switch engine {
        case .elevenLabs(let key):
            Task { await ElevenLabsClient.prewarm() }
            // With no voice picked, the first line would otherwise wait on a voices lookup before rendering.
            let configured = settings.elevenLabsVoiceID
            if configured.isEmpty, autoVoiceID == nil {
                Task { _ = try? await self.elevenLabsVoiceID(configured: configured, key: key) }
            }
        case .openAI:
            Task { await Self.headRequest("https://api.openai.com/v1/audio/speech") }
        case .local(let url, let voice):
            if launch {
                // The first Kokoro request loads the model (seconds); do it now rather than on her first line.
                let (stream, _) = Self.localSpeechStream(text: "Hi.", baseURL: url, voice: voice, settings: settings)
                Task { for try await _ in stream {} }
            } else {
                Task { await Self.headRequest(url + "/models") }
            }
        case .appleSystem:
            // A `say` process waiting on stdin with the voice loaded, plus a tiny render to keep the voice's
            // data in memory (a cold `say` start is seconds slower).
            spawnStandbySay(wordsPerMinute: Self.sayWordsPerMinute(settings.speechRate), voice: settings.sayVoice)
            let rate = settings.speechRate
            let voice = settings.sayVoice
            Task.detached(priority: .utility) { _ = try? Self.renderWithSay(text: "Hi.", rate: rate, voice: voice) }
        case .system:
            if launch {
                let utterance = AVSpeechUtterance(string: " ")
                utterance.voice = preferredVoice(settings)
                synthesizer.write(utterance) { _ in }
            }
        }
    }

    nonisolated private static func headRequest(_ string: String) async {
        guard let url = URL(string: string) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    struct SayVoice: Identifiable, Hashable, Sendable {
        var name: String
        var locale: String
        var id: String { name }
        /// Sound-effect voices (Bells, Bubbles, Zarvox…) that aren't useful for conversation.
        var isNovelty: Bool { Self.novelty.contains(name) }
        static let novelty: Set<String> = [
            "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Fred", "Good News", "Jester",
            "Junior", "Organ", "Ralph", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Kathy"
        ]
    }

    /// Every voice `say` can use, English first (the Siri voice in Spoken Content isn't listed; it's the default).
    nonisolated static func sayVoices() async -> [SayVoice] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-v", "?"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseSayVoices(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Parses `say -v '?'` lines like "Samantha            en_US    # Hello! My name is Samantha."
    nonisolated static func parseSayVoices(_ text: String) -> [SayVoice] {
        let voices = text.split(separator: "\n").compactMap { line -> SayVoice? in
            let head = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            guard let match = head.range(of: #"\s+[a-z]{2,3}_[A-Z0-9]{2,3}\s*$"#, options: .regularExpression) else { return nil }
            let name = head[..<match.lowerBound].trimmingCharacters(in: .whitespaces)
            let locale = head[match].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : SayVoice(name: name, locale: locale)
        }
        return voices.sorted { lhs, rhs in
            let le = lhs.locale.hasPrefix("en"), re = rhs.locale.hasPrefix("en")
            if le != re { return le }
            if lhs.isNovelty != rhs.isNovelty { return !lhs.isNovelty }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Voices the running Kokoro server offers (nil if it isn't reachable).
    func kokoroVoices() async -> [String]? {
        guard let url = URL(string: settingsProvider().localTTSURL)?.appendingPathComponent("audio/voices") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return nil }
        let list = (json["voices"]?.arrayValue ?? json.arrayValue ?? []).compactMap { $0.stringValue ?? $0["id"]?.stringValue }
        return list.isEmpty ? nil : list.sorted()
    }

    /// The engine that would speak right now (what "Automatic" resolves to), for the settings voice picker.
    var effectiveEngine: VoiceEngine {
        switch resolveEngine(settingsProvider()) {
        case .elevenLabs: return .elevenLabs
        case .openAI: return .openAI
        case .local: return .local
        case .appleSystem: return .appleSystem
        case .system: return .system
        }
    }

    /// The voice chosen in System Settings → Accessibility → Spoken Content (may be a Siri voice).
    static var systemVoiceName: String? {
        UserDefaults(suiteName: "com.apple.speech.voice.prefs")?.string(forKey: "SelectedVoiceName")
    }

    /// Checks (at most every 2 minutes) whether the local neural voice server is running.
    func probeLocalServer(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastLocalProbe) > 120 else { return }
        lastLocalProbe = Date()
        let base = settingsProvider().localTTSURL
        Task {
            let reachable = await Self.isReachable(base)
            self.localServerReachable = reachable
        }
    }

    private static func isReachable(_ base: String) async -> Bool {
        guard let url = URL(string: base)?.appendingPathComponent("models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }

    func refreshVoices() {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        availableVoices = english.sorted { lhs, rhs in
            let lq = Self.qualityRank(lhs), rq = Self.qualityRank(rhs)
            if lq != rq { return lq > rq }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Forget the auto-picked ElevenLabs voice (after the key or voice setting changes).
    func resetVoiceCache() {
        autoVoiceID = nil
        backoffUntil.removeAll()
        probeLocalServer(force: true)
    }

    // MARK: - Public API

    /// Speaks `text`. With `interrupt`, anything already playing is cut; otherwise it queues.
    func speak(_ text: String, interrupt: Bool = true) {
        let settings = settingsProvider()
        guard settings.voiceEnabled else { return }
        let cleaned = Self.spokenForm(text)
        guard !cleaned.isEmpty else { return }
        if interrupt { stop() }

        var chunker = SentenceChunker(minimumLength: 24)
        var sentences = chunker.feed(cleaned + " ")
        if let rest = chunker.flush() { sentences.append(rest) }

        LatencyTrace.shared.mark(.ttsRequest)
        let engine = resolveEngine(settings)
        let bias = toneProvider().prosodyBias
        for (index, sentence) in sentences.enumerated() {
            let previous = index > 0 ? sentences[index - 1] : queue.last?.text
            let next = index + 1 < sentences.count ? sentences[index + 1] : nil
            var prosody = Prosody.forLine(sentence, index: lineCounter, expressiveness: settings.voiceExpressiveness)
            prosody = Prosody(rate: prosody.rate * bias.rate, pitch: prosody.pitch * bias.pitch)
            lineCounter += 1
            queue.append(Line(text: sentence, previous: previous, next: next, engine: engine, prosody: prosody))
        }
        prefetch()
        if !isSpeaking { playNext() }
    }

    func stop() {
        generation += 1
        queue.forEach { $0.audio?.cancel() }
        queue.removeAll()
        spokenThisRun.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        streamPlayer.stop()
        liveSay?.discard()
        liveSay = nil
        lineCounter = 0
        isSpeaking = false
    }

    func previewCurrentVoice() {
        resetVoiceCache()
        speak("Well hey there, sugar! I'm Miss Minute. How's your day goin' so far? Hmm, let's keep it runnin' right on time... for all time, always!")
    }

    /// Mouth openness 0…1 at time `t` (seconds since reference date). Cheap; called every frame.
    func mouthOpenness(at t: TimeInterval) -> Double {
        guard isSpeaking else { return 0 }
        if streamPlayer.isPlaying {
            return streamPlayer.level * (0.6 + 0.4 * abs(sin(t * 14)))
        }
        if liveSay != nil {
            // `say` playing live gives no meter; flap on a syllable-ish rhythm.
            return 0.15 + 0.7 * abs(sin(t * 11)) * (0.55 + 0.45 * abs(sin(t * 2.3)))
        }
        if let player, player.isPlaying {
            player.updateMeters()
            let power = Double(player.averagePower(forChannel: 0)) // dB, -160…0
            let level = max(0, min(1, (power + 40) / 32))
            // Syllable flutter so it reads as talking, not a volume meter.
            return level * (0.6 + 0.4 * abs(sin(t * 14)))
        }
        let since = t - lastWordAt
        let wordDuration = 0.07 * Double(max(2, lastWordLength))
        guard since < wordDuration + 0.12 else { return 0.08 }
        let syllables = max(1.0, Double(lastWordLength) / 3)
        let flap = abs(sin(since / max(0.1, wordDuration) * .pi * syllables))
        return 0.2 + 0.8 * flap
    }

    // MARK: - Engine choice

    private func resolveEngine(_ settings: AppSettings) -> Engine {
        probeLocalServer()
        // Local-only mode never sends speech to the cloud.
        let eleven = settings.localOnly ? nil : secretProvider(SecretAccount.elevenLabs).flatMap { $0.isEmpty ? nil : $0 }
        let openAI = settings.localOnly ? nil : secretProvider(ProviderKind.openAI.keychainAccount).flatMap { $0.isEmpty ? nil : $0 }
        let local = Engine.local(url: settings.localTTSURL, voice: settings.localTTSVoice)
        func usable(_ engine: Engine) -> Bool {
            Date() >= (backoffUntil[engine.kind] ?? .distantPast)
        }

        var preference: [Engine] = []
        switch settings.voiceEngine {
        case .system:
            return .system
        case .appleSystem:
            preference = [.appleSystem]
        case .local:
            preference = [local, .appleSystem]
        case .elevenLabs:
            preference = (eleven.map { [Engine.elevenLabs(key: $0)] } ?? []) + [.appleSystem]
        case .openAI:
            preference = (openAI.map { [Engine.openAI(key: $0)] } ?? []) + [.appleSystem]
        case .auto:
            if let eleven { preference.append(.elevenLabs(key: eleven)) }
            if let openAI { preference.append(.openAI(key: openAI)) }
            if localServerReachable { preference.append(local) }
            preference.append(.appleSystem)
        }
        return preference.first(where: usable) ?? .system
    }

    /// Starts rendering the next few lines so each one is ready the moment the previous finishes.
    private func prefetch() {
        let settings = settingsProvider()
        for index in queue.indices.prefix(3) where queue[index].audio == nil {
            let line = queue[index]
            switch line.engine {
            case .system:
                continue
            case .elevenLabs(let key):
                let configuredVoice = settings.elevenLabsVoiceID
                let voiceID: @Sendable () async throws -> String = { [weak self] in
                    try await self?.elevenLabsVoiceID(configured: configuredVoice, key: key) ?? configuredVoice
                }
                let (stream, producer) = ElevenLabsClient.stream(
                    text: line.text, voiceID: voiceID, model: settings.elevenLabsModel, apiKey: key,
                    previousText: line.previous, nextText: line.next,
                    expressiveness: settings.voiceExpressiveness, speed: line.prosody.rate
                )
                queue[index].audio = .stream(stream, producer: producer)
            case .openAI(let key):
                let (stream, producer) = Self.openAISpeechStream(text: line.text, settings: settings, apiKey: key)
                queue[index].audio = .stream(stream, producer: producer)
            case .local(let url, let voice):
                let (stream, producer) = Self.localSpeechStream(
                    text: line.text, baseURL: url, voice: voice, settings: settings, rate: line.prosody.rate
                )
                queue[index].audio = .stream(stream, producer: producer)
            case .appleSystem:
                let rate = settings.speechRate
                let text = Self.sayText(line, wordsPerMinute: Self.sayWordsPerMinute(rate))
                let voice = settings.sayVoice
                let box = RenderBox()
                let task = Task.detached(priority: .userInitiated) {
                    try Self.renderWithSay(text: text, rate: rate, voice: voice)
                }
                Task { box.data = try? await task.value }
                queue[index].audio = .file(task, box)
            }
        }
    }

    private func elevenLabsVoiceID(configured: String, key: String) async throws -> String {
        if !configured.isEmpty { return configured }
        if let autoVoiceID { return autoVoiceID }
        guard let best = try await ElevenLabsClient.voices(apiKey: key).first else {
            throw ChatProviderError.underlying("Your ElevenLabs account has no voices.")
        }
        autoVoiceID = best.id
        return best.id
    }

    // MARK: - Playback

    private func playNext() {
        guard !queue.isEmpty else {
            let said = spokenThisRun.joined(separator: " ")
            spokenThisRun.removeAll()
            isSpeaking = false
            if !said.isEmpty { onFinishedSpeaking?(said) }
            return
        }
        let line = queue.removeFirst()
        Self.log.notice("line start [\(line.engine.name, privacy: .public)] \(line.text.count) chars, \(self.queue.count) queued")
        spokenThisRun.append(line.text)
        isSpeaking = true
        prefetch()
        activeEngineName = line.engine.name

        let gen = generation
        switch line.audio {
        case nil:
            speakWithSystemVoice(line)
        case .stream(let stream, _):
            streamPlayer.play(stream, onStart: { [weak self] in
                guard let self, gen == self.generation else { return }
                self.audioStarted(line.engine.name)
                self.lastEngineError = nil
            }, onFinish: { [weak self] error in
                guard let self, gen == self.generation else { return }
                if let error {
                    self.engineFailed(line, error: error)
                } else {
                    self.finishedCurrent()
                }
            })
        case .file(let task, let box):
            if let data = box.data {
                // Rendered while the previous line played: plays instantly, with a real lip-sync meter.
                playRendered(data, line: line)
            } else {
                // Rendering a file takes 1–4 s with `say`; speaking live starts as soon as synthesis does.
                task.cancel()
                speakLive(line)
            }
        }
    }

    private func playRendered(_ data: Data, line: Line) {
        do {
            try play(audio: data)
            audioStarted(line.engine.name)
            lastEngineError = nil
        } catch {
            engineFailed(line, error: error)
        }
    }

    /// Speaks a line with `say` straight to the speakers: audio starts as soon as synthesis does.
    private func speakLive(_ line: Line) {
        let settings = settingsProvider()
        let wpm = Self.sayWordsPerMinute(settings.speechRate)
        let voice = settings.sayVoice
        // A standby process has already loaded the voice: it starts talking ~15 ms after getting text,
        // versus ~750 ms for a fresh `say`.
        let standby = takeStandbySay(wordsPerMinute: wpm, voice: voice) ?? SayProcess(wordsPerMinute: wpm, voice: voice)
        let gen = generation
        standby.onExit = { [weak self, weak standby] status in
            Task { @MainActor in
                guard let self, gen == self.generation, let standby, self.liveSay === standby else { return }
                self.liveSay = nil
                if status == 0 {
                    self.finishedCurrent()
                } else {
                    self.engineFailed(line, error: ChatProviderError.underlying("say exited with \(status)"))
                }
            }
        }
        do {
            liveSay = standby
            try standby.speak(Self.sayText(line, wordsPerMinute: wpm))
            audioStarted(line.engine.name + " (live)")
            watchLiveSay(standby, line: line, wordsPerMinute: wpm)
        } catch {
            liveSay = nil
            engineFailed(line, error: error)
        }
        // Ready the next one right away for the following line.
        spawnStandbySay(wordsPerMinute: wpm, voice: voice)
    }

    /// Safety net: if a live line never reports finishing, move on instead of going silent for good.
    private func watchLiveSay(_ say: SayProcess, line: Line, wordsPerMinute: Int) {
        let words = max(1, line.text.split(separator: " ").count)
        let expected = Double(words) / Double(max(wordsPerMinute, 80)) * 60
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((expected * 1.6 + 4) * 1_000_000_000))
            guard let self, gen == self.generation, self.liveSay === say else { return }
            Self.log.error("live say never reported finishing; moving on")
            say.discard()
            self.liveSay = nil
            self.finishedCurrent()
        }
    }

    /// `say` ignores pitch commands with modern voices but honours `[[rate]]`, so vary the pace per line.
    nonisolated private static func sayText(_ line: Line, wordsPerMinute: Int) -> String {
        guard abs(line.prosody.rate - 1) > 0.005 else { return line.text }
        return "[[rate \(Int((Double(wordsPerMinute) * line.prosody.rate).rounded()))]] " + line.text
    }

    private var standbySay: SayProcess?

    /// A `say` left waiting too long has been seen to hang instead of speaking; keep standbys fresh.
    private static let standbyMaxAge: TimeInterval = 40

    private func takeStandbySay(wordsPerMinute: Int, voice: String) -> SayProcess? {
        defer { standbySay = nil }
        guard let standby = standbySay, standby.isWaiting, standby.wordsPerMinute == wordsPerMinute,
              standby.voice == voice, Date().timeIntervalSince(standby.createdAt) < Self.standbyMaxAge else {
            standbySay?.discard()
            return nil
        }
        return standby
    }

    private func spawnStandbySay(wordsPerMinute: Int, voice: String) {
        if let standby = standbySay, standby.isWaiting, standby.wordsPerMinute == wordsPerMinute, standby.voice == voice,
           Date().timeIntervalSince(standby.createdAt) < Self.standbyMaxAge - 10 {
            return
        }
        standbySay?.discard()
        let process = SayProcess(wordsPerMinute: wordsPerMinute, voice: voice)
        try? process.launch()
        standbySay = process
    }

    private func audioStarted(_ engineName: String) {
        activeEngineName = engineName
        let trace = LatencyTrace.shared
        if trace.has(.firstChunk) { trace.finish(engine: engineName) }
    }

    /// Back off this engine for a while and retry the line on the next one in line.
    private func engineFailed(_ line: Line, error: Error) {
        guard !(error is CancellationError) else { return }
        backoffUntil[line.engine.kind] = Date().addingTimeInterval(line.engine == .appleSystem ? 600 : 90)
        if line.engine == .local(url: settingsProvider().localTTSURL, voice: settingsProvider().localTTSVoice) {
            localServerReachable = false
        }
        let next = resolveEngine(settingsProvider())
        Self.log.error("\(line.engine.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        lastEngineError = "\(line.engine.name) voice failed (\(error.localizedDescription)). Switched to \(next.name)."
        for index in queue.indices where queue[index].engine == line.engine {
            queue[index].audio?.cancel()
            queue[index].audio = nil
            queue[index].engine = next
        }
        var retry = line
        retry.engine = next
        retry.audio = nil
        queue.insert(retry, at: 0)
        if !spokenThisRun.isEmpty { spokenThisRun.removeLast() }
        prefetch()
        playNext()
    }

    private func play(audio: Data) throws {
        let player = try AVAudioPlayer(data: audio)
        player.isMeteringEnabled = true
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        player.play()
    }

    private func speakWithSystemVoice(_ line: Line) {
        let settings = settingsProvider()
        let utterance = AVSpeechUtterance(string: line.text)
        utterance.voice = preferredVoice(settings)
        let rate = Float(min(max(settings.speechRate, 0.35), 0.7))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (0.9 + (rate - 0.5)) * Float(line.prosody.rate)
        utterance.pitchMultiplier = Float(1.1 * line.prosody.pitch)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.06
        synthesizer.speak(utterance)
    }

    nonisolated private static func expressivenessDirection(_ e: Double) -> String {
        switch e {
        case ..<0.3: return " Keep the delivery calm and even."
        case ..<0.7: return " Let the pitch rise and fall naturally with the meaning; lively but not over the top."
        default: return " Be very animated: big swings in pitch and pace, playful emphasis, real excitement on good news."
        }
    }

    /// OpenAI TTS as streamed raw 24 kHz PCM.
    private static func openAISpeechStream(
        text: String, settings: AppSettings, apiKey: String
    ) -> (AsyncThrowingStream<Data, Error>, Task<Void, Never>) {
        let body: [String: Any] = [
            "model": settings.neuralVoiceModel,
            "voice": settings.neuralVoice,
            "input": text,
            "instructions": neuralStyle + expressivenessDirection(settings.voiceExpressiveness),
            "response_format": "pcm"
        ]
        let payload = try? JSONSerialization.data(withJSONObject: body)
        return PCMHTTPStream.open {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        } errorPrefix: { "OpenAI voice \($0)" }
    }

    /// OpenAI-compatible local server (Kokoro-FastAPI and similar), streamed as raw 24 kHz PCM.
    private static func localSpeechStream(
        text: String, baseURL: String, voice: String, settings: AppSettings, rate: Double = 1
    ) -> (AsyncThrowingStream<Data, Error>, Task<Void, Never>) {
        let speed = (0.85 + (min(max(settings.speechRate, 0.4), 0.65) - 0.4) * 1.2) * rate // 0.85…1.15 × prosody
        let body: [String: Any] = [
            "model": "kokoro",
            "input": text,
            "voice": voice,
            "response_format": "pcm",
            "stream": true,
            "speed": speed
        ]
        let payload = try? JSONSerialization.data(withJSONObject: body)
        return PCMHTTPStream.open {
            guard let url = URL(string: baseURL)?.appendingPathComponent("audio/speech") else {
                throw ChatProviderError.invalidURL(baseURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        } errorPrefix: { "Kokoro \($0)" }
    }

    /// 0.4…0.65 → ~160…220 words per minute (default ≈ 185).
    nonisolated static func sayWordsPerMinute(_ rate: Double) -> Int {
        Int(160 + (min(max(rate, 0.4), 0.65) - 0.4) * 240)
    }

    /// Renders a sentence with `say`, which speaks with the Mac's selected system voice — including Siri voices,
    /// which apps can't otherwise use. Returns AIFF audio.
    nonisolated private static func renderWithSay(text: String, rate: Double, voice: String = "") throws -> Data {
        let dir = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let input = dir.appendingPathComponent("mm-say-\(id).txt")
        let output = dir.appendingPathComponent("mm-say-\(id).aiff")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try text.write(to: input, atomically: false, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = (voice.isEmpty ? [] : ["-v", voice]) + ["-r", String(sayWordsPerMinute(rate)), "-f", input.path, "-o", output.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChatProviderError.underlying("say exited with \(process.terminationStatus)")
        }
        let data = try Data(contentsOf: output)
        // An empty AIFF header (~4 KB) means nothing was rendered.
        guard data.count > 8_192 else { throw ChatProviderError.underlying("say produced no audio") }
        return data
    }

    private func finishedCurrent() {
        Self.log.notice("line done")
        player = nil
        playNext()
    }

    // MARK: - Delegates

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let length = characterRange.length
        Task { @MainActor in
            self.lastWordAt = Date.timeIntervalSinceReferenceDate
            self.lastWordLength = length
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.audioStarted(Engine.system.name) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedCurrent() }
    }

    // Cancellation only happens through `stop()`, which already reset state.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishedCurrent() }
    }

    // MARK: - macOS voice selection

    private func preferredVoice(_ settings: AppSettings) -> AVSpeechSynthesisVoice? {
        if !settings.voiceIdentifier.isEmpty,
           let exact = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) {
            return exact
        }
        let voices = availableVoices.isEmpty
            ? AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            : availableVoices
        let preferredNames = ["Zoe", "Ava", "Allison", "Samantha", "Susan", "Nicky", "Nora", "Evan"]
        for name in preferredNames {
            if let match = voices.first(where: { $0.name.localizedCaseInsensitiveContains(name) && Self.qualityRank($0) >= 2 }) {
                return match
            }
        }
        if let premium = voices.first(where: { Self.qualityRank($0) >= 2 && $0.language.hasPrefix("en-US") }) {
            return premium
        }
        return AVSpeechSynthesisVoice(language: "en-US") ?? voices.first
    }

    /// True when only robotic standard-quality macOS voices are installed.
    var hasOnlyStandardSystemVoices: Bool {
        !availableVoices.contains { Self.qualityRank($0) >= 2 }
    }

    private static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// Strip markdown, emoji, and links so speech sounds natural.
    static func spokenForm(_ text: String) -> String {
        var s = text
        let patterns: [(String, String)] = [
            (#"```[\s\S]*?```"#, " (the code's in the chat) "),
            (#"\*\*(.+?)\*\*"#, "$1"),
            (#"\*(.+?)\*"#, "$1"),
            (#"`(.+?)`"#, "$1"),
            (#"\[(.+?)\]\(.+?\)"#, "$1"),
            (#"https?://\S+"#, "that link"),
            (#"(?m)^\s*#+\s*"#, ""),
            (#"(?m)^\s*[-•]\s+"#, "")
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
            }
        }
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !$0.properties.isEmojiPresentation }))
        s = s
            .replacingOccurrences(of: "…", with: "...")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 900 {
            s = String(s.prefix(897)) + "..."
        }
        return s
    }
}
