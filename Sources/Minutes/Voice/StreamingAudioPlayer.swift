import AVFoundation
import MinutesCore

/// Plays raw PCM while it's still downloading, so a cloud or local neural voice starts within a few hundred
/// milliseconds instead of after the whole sentence has rendered. The engine is started once and kept running.
@MainActor
final class StreamingAudioPlayer {
    /// Every streaming engine we use (ElevenLabs pcm_24000, OpenAI pcm, Kokoro pcm) sends 24 kHz mono.
    static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: StreamingAudioPlayer.sampleRate, channels: 1)!
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    private let meter = LevelMeter()

    /// Loudness of what's playing right now (0…1), for lip-sync.
    var level: Double { meter.value }
    private(set) var isPlaying = false

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        let meter = self.meter
        node.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let samples = UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
            meter.value = PCMStreamDecoder.level(ArraySlice(samples))
        }
        // Output device changes (headphones, AirPods) stop the engine; bring it back.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
    }

    /// Starts the audio engine ahead of time (starting it costs ~50–100 ms).
    func prewarm() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    /// Plays `chunks` as they arrive. `onStart` fires when the first audio is scheduled; `onFinish` once
    /// everything has played (error is non-nil only if the stream failed before any audio played).
    func play(
        _ chunks: AsyncThrowingStream<Data, Error>,
        onStart: @escaping () -> Void,
        onFinish: @escaping (Error?) -> Void
    ) {
        stop()
        prewarm()
        generation += 1
        let gen = generation
        isPlaying = true
        var decoder = PCMStreamDecoder()
        var pending: [Float] = []
        var started = false
        var outstanding = 0
        var producerDone = false

        func finishIfDone() {
            guard gen == self.generation, producerDone, outstanding == 0 else { return }
            self.isPlaying = false
            self.meter.value = 0
            onFinish(nil)
        }
        func schedule(_ samples: [Float]) {
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            outstanding += 1
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                Task { @MainActor in
                    outstanding -= 1
                    finishIfDone()
                }
            }
            if !started {
                started = true
                if !node.isPlaying { node.play() }
                onStart()
            }
        }

        Task {
            do {
                for try await chunk in chunks {
                    guard gen == self.generation else { return }
                    pending += decoder.feed(chunk)
                    if pending.count >= Self.scheduleThreshold(started: started, queuedBuffers: outstanding) {
                        schedule(pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                guard gen == self.generation else { return }
                schedule(pending)
                producerDone = true
                finishIfDone()
            } catch {
                guard gen == self.generation else { return }
                producerDone = true
                if started {
                    finishIfDone()
                } else {
                    self.isPlaying = false
                    onFinish(error)
                }
            }
        }
    }

    /// Samples to collect before scheduling. Start on ~25 ms (the first network chunk); after that, top up
    /// right away when the queue is nearly dry (avoids a gap if the stream is only just keeping up), and batch
    /// ~100 ms buffers when there's plenty queued.
    static func scheduleThreshold(started: Bool, queuedBuffers: Int) -> Int {
        guard started else { return Int(sampleRate * 0.025) }
        return queuedBuffers <= 1 ? 1 : Int(sampleRate * 0.1)
    }

    func stop() {
        generation += 1
        node.stop()
        isPlaying = false
        meter.value = 0
    }

    private func restart() {
        let wasPlaying = isPlaying
        engine.stop()
        prewarm()
        if wasPlaying { node.play() }
    }
}

/// Written on the audio thread, read on the main thread.
private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double = 0
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
