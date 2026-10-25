import AVFoundation
import MinutesCore
import Speech
import os

/// Listens for "Hey Minute" with on-device speech recognition (audio never leaves the Mac).
///
/// "Hey Minute, what's on my calendar?" in one breath delivers the request directly; "Hey Minute" alone
/// calls `onWakeOnly` so the app can open the mic for the request. It pauses whenever `canListen` says so
/// (she's talking, push-to-talk is open, a call is on) — call `refresh()` when those change.
@MainActor
final class WakeWordListener {
    /// The request after the wake phrase, and when the user last spoke (for latency tracing).
    var onCommand: ((String, TimeInterval?) -> Void)?
    var onWakeOnly: (() -> Void)?
    /// Live text after the wake phrase, for the "listening" bubble (nil when done).
    var onPartial: ((String?) -> Void)?
    var canListen: () -> Bool = { false }

    private static let log = Logger(subsystem: "com.minutes.app", category: "wake")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var session = 0
    private var restartTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var heardWake = false
    private var command = ""
    private var lastSpeechAt: TimeInterval?
    private var transcriptLength = 0
    private(set) var isRunning = false
    private(set) var unavailableReason: String?

    /// Starts or stops listening to match `canListen()`.
    func refresh() {
        if canListen() {
            if !isRunning { start() }
        } else if isRunning {
            stop()
        }
    }

    private func start() {
        guard let recognizer, recognizer.isAvailable else {
            unavailableReason = "Speech recognition isn't available."
            return
        }
        // Wake listening is always on, so it must stay on the Mac.
        guard recognizer.supportsOnDeviceRecognition else {
            unavailableReason = "This Mac can't recognise speech on-device, so “Hey Minute” stays off."
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            unavailableReason = "Needs Microphone and Speech Recognition access (use push-to-talk once to grant it)."
            requestPermissionsIfNeeded()
            return
        }
        unavailableReason = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.contextualStrings = ["Hey Minute", "Miss Minute", "Hey Miss Minute"]
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: Self.makeTap(request: request))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            unavailableReason = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        session += 1
        let current = session
        heardWake = false
        command = ""
        lastSpeechAt = nil
        isRunning = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler { [weak self] text, failed in
            Task { @MainActor in
                guard let self, self.session == current, self.isRunning else { return }
                if let text { self.handle(text) }
                guard failed, self.isRunning else { return }
                // Recognition ended on its own: deliver what was said after the wake phrase, else start over.
                if self.heardWake { self.deliver() } else { self.restartSoon(after: 1) }
            }
        })
        // Recognition tasks are meant for utterances, not hours: start a fresh one regularly while idle.
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000_000)
            guard let self, !Task.isCancelled, self.session == current, !self.heardWake else { return }
            self.restartSoon(after: 0)
        }
        Self.log.notice("listening for wake word")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        session += 1
        restartTask?.cancel()
        silenceTask?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if heardWake { onPartial?(nil) }
        heardWake = false
    }

    private func restartSoon(after seconds: Double) {
        stop()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.refresh()
        }
    }

    private func handle(_ text: String) {
        let changed = text.count != transcriptLength
        transcriptLength = text.count
        if !heardWake {
            // Only look at the recent tail so an old mention doesn't re-trigger.
            guard let found = WakePhrase.command(in: String(text.suffix(160))) else {
                if text.count > 400 { restartSoon(after: 0) }
                return
            }
            heardWake = true
            restartTask?.cancel()
            command = found
            lastSpeechAt = ProcessInfo.processInfo.systemUptime
            Self.log.notice("wake word heard")
            onPartial?(command)
            armSilence()
            return
        }
        if let found = WakePhrase.command(in: text), changed {
            command = found
            lastSpeechAt = ProcessInfo.processInfo.systemUptime
            onPartial?(command)
            armSilence()
        }
    }

    /// The request is over after a short pause (a bit longer if they've only said "Hey Minute" so far).
    private func armSilence() {
        silenceTask?.cancel()
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let finished = trimmed.split(separator: " ").count >= 3 && [".", "?", "!"].contains(where: trimmed.hasSuffix)
        let wait = trimmed.isEmpty ? 1.1 : (finished ? 0.55 : 0.8)
        let current = session
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, self.session == current else { return }
            self.deliver()
        }
    }

    private func deliver() {
        let request = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokeAt = lastSpeechAt
        stop()
        onPartial?(nil)
        if request.isEmpty {
            onWakeOnly?()
        } else {
            onCommand?(request, spokeAt)
        }
    }

    private var askedForPermission = false

    private func requestPermissionsIfNeeded() {
        guard !askedForPermission else { return }
        askedForPermission = true
        let speechUndetermined = SFSpeechRecognizer.authorizationStatus() == .notDetermined
        let micUndetermined = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        guard speechUndetermined || micUndetermined else { return }
        Task {
            if speechUndetermined {
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
                }
            }
            if micUndetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            self.refresh()
        }
    }

    // Audio and recognition callbacks run off the main thread; build them outside main-actor isolation.
    nonisolated private static func makeTap(request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func makeResultHandler(
        _ sink: @escaping @Sendable (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            sink(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }
}
