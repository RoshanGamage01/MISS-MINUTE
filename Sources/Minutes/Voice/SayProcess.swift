import Foundation

/// A `say` process started ahead of time that waits for its text on stdin, so the system voice is already
/// loaded when Miss Minute needs it. Speaking writes the text and closes stdin; `say` then speaks it live.
final class SayProcess: @unchecked Sendable {
    let wordsPerMinute: Int
    /// `say -v` name; empty = the system voice.
    let voice: String
    let process = Process()
    let createdAt = Date()
    private let input = Pipe()
    private let lock = NSLock()
    private var exitHandler: ((Int32) -> Void)?
    private var spoke = false

    /// Called with the exit status once speech finishes (or the process dies).
    var onExit: ((Int32) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return exitHandler }
        set { lock.lock(); exitHandler = newValue; lock.unlock() }
    }

    init(wordsPerMinute: Int, voice: String = "", executable: URL = URL(fileURLWithPath: "/usr/bin/say")) {
        self.wordsPerMinute = wordsPerMinute
        self.voice = voice
        process.executableURL = executable
        process.arguments = (voice.isEmpty ? [] : ["-v", voice]) + ["-r", String(wordsPerMinute), "-f", "-"]
        process.standardInput = input
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] finished in
            self?.onExit?(finished.terminationStatus)
        }
    }

    /// Still waiting for text (launched, not yet used, not dead).
    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return process.isRunning && !spoke
    }

    func launch() throws {
        try process.run()
    }

    func speak(_ text: String) throws {
        if !process.isRunning { try launch() }
        lock.lock(); spoke = true; lock.unlock()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
    }

    /// Ends an unused standby without speaking.
    func discard() {
        onExit = nil
        if process.isRunning { process.terminate() }
    }
}
