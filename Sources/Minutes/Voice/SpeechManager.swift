import AVFoundation
import Combine
import MinutesCore

/// Speaks Miss Minute's lines and drives her lip-sync.
///
/// Engines: paid cloud voices (ElevenLabs, OpenAI) when keys exist, a free local neural server (Kokoro),
/// the Mac's system voice rendered with `say` (which can be a Siri voice), and AVSpeechSynthesizer as the last
/// resort. Text is spoken sentence by sentence; the next sentence's audio renders while the current one plays.
@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechManager()

    @Published private(set) var isSpeaking = false
    @Published private(set) var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var lastEngineError: String?
    /// Which engine actually spoke last ("ElevenLabs", "OpenAI", "macOS").
    @Published private(set) var activeEngineName = "macOS"

    /// Fires when a spoken line finishes and nothing else is queued, with the full text that was said.
    var onFinishedSpeaking: ((String) -> Void)?

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

    private struct Line {
        var text: String
        var previous: String?
        var next: String?
        var engine: Engine
        var audio: Task<Data, Error>?
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
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

        let engine = resolveEngine(settings)
        for (index, sentence) in sentences.enumerated() {
            let previous = index > 0 ? sentences[index - 1] : queue.last?.text
            let next = index + 1 < sentences.count ? sentences[index + 1] : nil
            queue.append(Line(text: sentence, previous: previous, next: next, engine: engine))
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
        isSpeaking = false
    }

    func previewCurrentVoice() {
        resetVoiceCache()
        speak("Well hey there, sugar! I'm Miss Minute. I'll keep your day runnin' right on time — for all time, always.")
    }

    /// Mouth openness 0…1 at time `t` (seconds since reference date). Cheap; called every frame.
    func mouthOpenness(at t: TimeInterval) -> Double {
        guard isSpeaking else { return 0 }
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
                let model = settings.elevenLabsModel
                queue[index].audio = Task { [weak self] in
                    let voiceID = try await self?.elevenLabsVoiceID(configured: configuredVoice, key: key) ?? configuredVoice
                    return try await ElevenLabsClient.synthesize(
                        text: line.text, voiceID: voiceID, model: model, apiKey: key,
                        previousText: line.previous, nextText: line.next
                    )
                }
            case .openAI(let key):
                queue[index].audio = Task {
                    try await Self.fetchOpenAISpeech(text: line.text, settings: settings, apiKey: key)
                }
            case .local(let url, let voice):
                queue[index].audio = Task {
                    try await Self.fetchLocalSpeech(text: line.text, baseURL: url, voice: voice, settings: settings)
                }
            case .appleSystem:
                let rate = settings.speechRate
                let text = line.text
                queue[index].audio = Task.detached(priority: .userInitiated) {
                    try Self.renderWithSay(text: text, rate: rate)
                }
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
        spokenThisRun.append(line.text)
        isSpeaking = true
        prefetch()
        activeEngineName = line.engine.name

        guard let audio = line.audio else {
            speakWithSystemVoice(line.text)
            return
        }
        let gen = generation
        Task {
            do {
                let data = try await audio.value
                guard gen == self.generation else { return }
                try self.play(audio: data)
                self.lastEngineError = nil
            } catch {
                guard gen == self.generation, !(error is CancellationError) else { return }
                // Back off this engine for a while and retry the line on the next one in line.
                self.backoffUntil[line.engine.kind] = Date().addingTimeInterval(line.engine == .appleSystem ? 600 : 90)
                if line.engine == .local(url: self.settingsProvider().localTTSURL, voice: self.settingsProvider().localTTSVoice) {
                    self.localServerReachable = false
                }
                let next = self.resolveEngine(self.settingsProvider())
                self.lastEngineError = "\(line.engine.name) voice failed (\(error.localizedDescription)). Switched to \(next.name)."
                for index in self.queue.indices where self.queue[index].engine == line.engine {
                    self.queue[index].audio?.cancel()
                    self.queue[index].audio = nil
                    self.queue[index].engine = next
                }
                var retry = line
                retry.engine = next
                retry.audio = nil
                self.queue.insert(retry, at: 0)
                self.spokenThisRun.removeLast()
                self.prefetch()
                self.playNext()
            }
        }
    }

    private func play(audio: Data) throws {
        let player = try AVAudioPlayer(data: audio)
        player.isMeteringEnabled = true
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        player.play()
    }

    private func speakWithSystemVoice(_ text: String) {
        let settings = settingsProvider()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice(settings)
        let rate = Float(min(max(settings.speechRate, 0.35), 0.7))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (0.9 + (rate - 0.5))
        utterance.pitchMultiplier = 1.1
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.06
        synthesizer.speak(utterance)
    }

    private static func fetchOpenAISpeech(text: String, settings: AppSettings, apiKey: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": settings.neuralVoiceModel,
            "voice": settings.neuralVoice,
            "input": text,
            "instructions": neuralStyle,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ChatProviderError.httpStatus(code, String(decoding: data.prefix(400), as: UTF8.self))
        }
        return data
    }

    /// OpenAI-compatible local server (Kokoro-FastAPI and similar).
    private static func fetchLocalSpeech(text: String, baseURL: String, voice: String, settings: AppSettings) async throws -> Data {
        guard let url = URL(string: baseURL)?.appendingPathComponent("audio/speech") else {
            throw ChatProviderError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let speed = 0.85 + (min(max(settings.speechRate, 0.4), 0.65) - 0.4) * 1.2 // 0.85…1.15
        let body: [String: Any] = [
            "model": "kokoro",
            "input": text,
            "voice": voice,
            "response_format": "mp3",
            "speed": speed
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ChatProviderError.httpStatus(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    /// Renders a sentence with `say`, which speaks with the Mac's selected system voice — including Siri voices,
    /// which apps can't otherwise use. Returns AIFF audio.
    nonisolated private static func renderWithSay(text: String, rate: Double) throws -> Data {
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
        // 0.4…0.65 → ~160…220 words per minute (default ≈ 185).
        let wpm = Int(160 + (min(max(rate, 0.4), 0.65) - 0.4) * 240)
        process.arguments = ["-r", String(wpm), "-f", input.path, "-o", output.path]
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
