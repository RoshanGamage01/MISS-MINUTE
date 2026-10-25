import AppKit
import Combine
import SwiftUI

/// A TVA-style speech bubble that pops up beside Miss Minute, types out her line, then fades.
@MainActor
final class SpeechBubbleController {
    private var panel: NSPanel?
    private let model = BubbleModel()
    private var hideTask: Task<Void, Never>?
    var anchorFrame: () -> NSRect? = { nil }
    var onClick: (() -> Void)?

    func show(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ensurePanel()
        model.present(trimmed)
        layout()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()

        hideTask?.cancel()
        let words = trimmed.split(separator: " ").count
        let seconds = min(18, max(4.5, Double(words) * 0.42 + 2))
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Live text while the user is talking.
    func showListening(_ text: String?) {
        ensurePanel()
        if let text {
            hideTask?.cancel()
            model.presentImmediately("“\(text)”", listening: true)
            layout()
            panel?.alphaValue = 1
            panel?.orderFrontRegardless()
        } else if model.isListening {
            hide()
        }
    }

    func setClickThrough(_ enabled: Bool) {
        ensurePanel()
        panel?.ignoresMouseEvents = enabled
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel?.alphaValue == 0 else { return }
                self.panel?.orderOut(nil)
                self.model.isListening = false
            }
        })
    }

    func layout() {
        guard let panel, let anchor = anchorFrame(), let screen = NSScreen.main else { return }
        let width: CGFloat = 300
        // Text area = width minus outer (8) and inner (14) padding on both sides.
        let font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        let textHeight = (model.sizingText as NSString).boundingRect(
            with: NSSize(width: width - 44, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        let height = min(320, max(56, ceil(textHeight * 1.12) + 22 + 16))
        let visible = screen.visibleFrame
        // Prefer the side of the character with more room; sit at eye level.
        let roomLeft = anchor.minX - visible.minX
        let roomRight = visible.maxX - anchor.maxX
        var x = roomLeft > roomRight ? anchor.minX - width + 24 : anchor.maxX - 24
        var y = anchor.minY + anchor.height * 0.62
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
        model.tailOnRight = roomLeft > roomRight
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let view = BubbleView(model: model, onClick: { [weak self] in
            self?.hide()
            self?.onClick?()
        })
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        self.panel = panel
    }
}

@MainActor
final class BubbleModel: ObservableObject {
    @Published var shown = ""
    @Published var tailOnRight = false
    @Published var isListening = false
    private var full = ""
    private var typing: Task<Void, Never>?

    func present(_ text: String) {
        typing?.cancel()
        isListening = false
        full = text
        shown = ""
        // Typewriter reveal at roughly speaking pace.
        typing = Task { [weak self] in
            var index = text.startIndex
            while index < text.endIndex {
                guard let self, !Task.isCancelled else { return }
                let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                self.shown = String(text[..<next])
                index = next
                try? await Task.sleep(nanoseconds: 28_000_000)
            }
        }
    }

    func presentImmediately(_ text: String, listening: Bool) {
        typing?.cancel()
        isListening = listening
        full = text
        shown = text
    }

    /// Full text, so the bubble sizes itself to the final line from the start.
    var sizingText: String { full }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    var onClick: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Invisible full text reserves the final size.
            Text(model.sizingText).opacity(0)
            Text(model.shown)
        }
        .font(.system(size: 13.5, weight: .medium, design: .rounded))
        .foregroundStyle(MinutesTheme.cream)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.07, blue: 0.03).opacity(0.94))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [MinutesTheme.amber, MinutesTheme.amber.opacity(0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.2
                    )
            }
            .shadow(color: MinutesTheme.amber.opacity(0.35), radius: 10)
        )
        .overlay(alignment: .topLeading) {
            if model.isListening {
                MinutesTheme.label("listening")
                    .foregroundStyle(MinutesTheme.amber)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color(red: 0.13, green: 0.07, blue: 0.03)))
                    .offset(x: 12, y: -7)
            }
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}
