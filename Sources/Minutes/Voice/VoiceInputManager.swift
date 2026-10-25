import AVFoundation
import Combine
import Speech
import MinutesCore

/// Push-to-talk speech recognition. Stops on its own after a short silence and hands back the transcript.
@MainActor
final class VoiceInputManager: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    /// 0…1 input level for the UI.
    @Published private(set) var level: Double = 0

    var onFinal: ((String) -> Void)?
    var onStateChange: ((Bool) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?

    /// Seconds of silence after speech that end the utterance. This wait is the first thing between the user
    /// finishing and her answering, so keep it short.
    var silenceTimeout: TimeInterval = 0.8
    /// When the transcript last changed (≈ when the user last spoke), for latency tracing.
    private var lastSpeechAt: TimeInterval?

    func toggle() {
        if isListening {
            stop(deliver: true)
        } else {
            Task { await start() }
        }
    }

    /// - Parameter noSpeechTimeout: give up if nothing is said within this many seconds.
    func start(noSpeechTimeout: TimeInterval = 7) async {
        guard !isListening else { return }
        errorMessage = nil
        guard await Self.requestPermissions() else {
            errorMessage = "I need Microphone and Speech Recognition access — System Settings → Privacy & Security."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(request: request) { [weak self] level in
            Task { @MainActor in self?.level = level }
        })

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        transcript = ""
        lastSpeechAt = nil
        isListening = true
        onStateChange?(true)

        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeResultHandler { [weak self] text, isFinal, failed in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if let text {
                    if text != self.transcript { self.lastSpeechAt = ProcessInfo.processInfo.systemUptime }
                    self.transcript = text
                    self.armSilenceTimer()
                }
                if isFinal || (failed && text == nil) {
                    self.stop(deliver: true)
                }
            }
        })

        // Hard cap so a forgotten mic doesn't stay hot.
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop(deliver: true)
        }
        // If nothing is said at all, give up after a while.
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(noSpeechTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.transcript.isEmpty else { return }
            self.stop(deliver: false)
        }
    }

    func stop(deliver: Bool) {
        guard isListening else { return }
        isListening = false
        silenceTask?.cancel()
        maxDurationTask?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        onStateChange?(false)

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if deliver, !text.isEmpty {
            let trace = LatencyTrace.shared
            trace.begin(origin: "spoken", at: lastSpeechAt)
            trace.mark(.speechEnded, at: lastSpeechAt)
            trace.mark(.sttFinal)
            onFinal?(text)
        }
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        // When the recognizer has already punctuated a finished sentence, a shorter pause is enough.
        let trimmed = transcript.trimmingCharacters(in: .whitespaces)
        let sentenceDone = trimmed.split(separator: " ").count >= 3 && [".", "?", "!"].contains(where: trimmed.hasSuffix)
        let timeout = sentenceDone ? min(silenceTimeout, 0.55) : silenceTimeout
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(deliver: true)
        }
    }

    nonisolated private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // Audio and recognition callbacks run off the main thread; build them outside main-actor isolation.
    nonisolated private static func makeTap(
        request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping @Sendable (Double) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            onLevel(rms(buffer))
        }
    }

    nonisolated private static func makeResultHandler(
        _ sink: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            sink(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        return min(1, Double(rms) * 12)
    }
}
