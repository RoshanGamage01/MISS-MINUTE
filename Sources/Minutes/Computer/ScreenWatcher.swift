import AppKit
import MinutesCore

/// "Always aware" mode: every few minutes Miss Minute glances at the screen, keeps a short note of what the
/// user is doing (fed into every conversation), and offers help when she sees something she can do.
@MainActor
final class ScreenWatcher {
    var settings: () -> AppSettings = { .default }
    var makeProvider: () throws -> any ChatProvider = { throw ChatProviderError.underlying("No provider") }
    /// True when she shouldn't glance (in a conversation, on a call…).
    var isBusy: () -> Bool = { false }
    var onOffer: ((String) -> Void)?
    /// Each new note (the proactive engine scans them for errors the user may be stuck on).
    var onNote: ((String) -> Void)?

    private let computer: ComputerController
    private var timer: Timer?
    private var lastGlance: Date = .distantPast
    private var lastSignature = ""
    private var notes: [(date: Date, text: String)] = []
    private var offers: [String] = []
    private var running = false

    init(computer: ComputerController) {
        self.computer = computer
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickIfDue() }
        }
    }

    /// Something looks wrong on screen: glance on the next tick instead of waiting out the interval
    /// (still only in "always aware" mode, and never mid-conversation).
    func glanceSoon() {
        guard Date().timeIntervalSince(lastGlance) > 60 else { return }
        lastGlance = .distantPast
        lastSignature = ""
    }

    /// Notes for the context block, oldest first, e.g. "14:05 — Editing invoice.xlsx in Numbers".
    var recentNotes: [String] {
        let cutoff = Date().addingTimeInterval(-90 * 60)
        return notes.filter { $0.date > cutoff }.suffix(5).map {
            "\($0.date.formatted(date: .omitted, time: .shortened)) — \($0.text)"
        }
    }

    private func tickIfDue() async {
        let s = settings()
        guard s.screenAwareness == .continuous, !running, !isBusy(),
              Date().timeIntervalSince(lastGlance) >= Double(max(1, s.screenGlanceMinutes)) * 60,
              SystemIdle.idleSeconds() < 120 else { return }
        await glance()
    }

    /// Looks at the screen once and records what's going on.
    func glance() async {
        running = true
        defer { running = false }
        lastGlance = Date()

        let (app, title) = computer.frontSummary()
        var images: [ImageAttachment] = []
        var uiText = ""
        if ScreenCapture.hasPermission, let shot = try? await ScreenCapture.capture(maxDimension: 900, quality: 0.5) {
            images = [shot.image]
        } else if AXIsProcessTrusted(), let target = computer.targetApp {
            uiText = String(computer.reader.snapshot(of: target, maxNodes: 120, maxChars: 2_500).text)
        }
        guard !images.isEmpty || !uiText.isEmpty || app != nil else { return }

        // Skip if nothing obviously changed and the last note is fresh.
        let signature = "\(app ?? "")|\(title ?? "")|\(images.first.map { $0.base64.count / 4_000 } ?? 0)"
        if signature == lastSignature, let last = notes.last, Date().timeIntervalSince(last.date) < 12 * 60 { return }
        lastSignature = signature

        guard let provider = try? makeProvider() else { return }
        var prompt = """
        Quick glance at the user's screen (an automatic check, not a message from them). \
        Front app: \(app ?? "unknown")\(title.map { ", window \"\($0)\"" } ?? "").
        Reply in exactly two lines:
        NOTE: one specific sentence about what they're doing right now (app, topic, file, page, problem). If an \
        error, failed build, crash, or warning dialog is visible, say so and quote its key message.
        OFFER: one short spoken line offering concrete help with what you see — an error you could explain, \
        something you could look up, a task you could do — or "none" if they're just working fine. \
        Offer rarely; never interrupt focused work for small talk.
        """
        if !offers.isEmpty {
            prompt += "\nDon't repeat these earlier offers: " + offers.suffix(3).joined(separator: " | ")
        }
        if !uiText.isEmpty {
            prompt += "\n\nWindow contents (accessibility text):\n" + uiText
        }

        var reply = ""
        do {
            let stream = provider.streamChat(
                messages: [ChatMessage(role: .user, content: prompt, images: images.isEmpty ? nil : images)],
                model: settings().model,
                systemPrompt: settings().personaPrompt,
                depth: .snappy
            )
            for try await chunk in stream {
                reply += chunk
                if reply.count > 800 { break }
            }
        } catch {
            return
        }

        let (note, offer) = Self.parse(reply)
        if let note {
            notes.append((Date(), note))
            if notes.count > 30 { notes.removeFirst(notes.count - 30) }
            onNote?(note)
        }
        if let offer, !isBusy() {
            offers.append(offer)
            onOffer?(offer)
        }
    }

    static func parse(_ reply: String) -> (note: String?, offer: String?) {
        var note: String?
        var offer: String?
        for line in reply.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("NOTE:") {
                note = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("OFFER:") {
                let text = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "?!")))
                if !text.isEmpty, text.lowercased() != "none", !text.lowercased().hasPrefix("none") { offer = text }
            }
        }
        return (note?.isEmpty == false ? note : nil, offer)
    }
}
