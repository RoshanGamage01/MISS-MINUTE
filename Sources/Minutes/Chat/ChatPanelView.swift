import SwiftUI
import MinutesCore

struct ChatPanelView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ChatPanelContent(chat: appModel.chatService)
            .environmentObject(appModel)
            .preferredColorScheme(
                MinutesTheme.preferredColorScheme(for: appModel.settingsStore.settings.appearance)
            )
    }
}

private struct ChatPanelContent: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var chat: ChatService
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(colorScheme == .dark ? 0.3 : 1)
            messageList
            if let activity = appModel.latestActivitySummary {
                Text(activity)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if let error = chat.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Divider().opacity(colorScheme == .dark ? 0.3 : 1)
            composer
        }
        .frame(minWidth: 320, minHeight: 400)
        .background(MinutesTheme.panelBackground(for: colorScheme))
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Minutes")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Text(appModel.settingsStore.settings.provider.displayName)
                    if appModel.settingsStore.settings.voiceEnabled {
                        Image(systemName: appModel.speech.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.caption2)
                    }
                    if appModel.settingsStore.settings.activityMonitoringEnabled {
                        Image(systemName: "eye")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if appModel.speech.isSpeaking {
                Button("Stop voice") { appModel.speech.stop() }
                    .buttonStyle(.borderless)
            }
            Button("Clear") {
                Task { await chat.clearHistory() }
            }
            .buttonStyle(.borderless)
            Button {
                appModel.openSettingsRequested()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.conversation.messages.isEmpty && chat.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(chat.conversation.messages) { message in
                        MessageBubble(message: message, colorScheme: colorScheme)
                            .id(message.id)
                    }
                    if !chat.streamingText.isEmpty {
                        MessageBubble(
                            message: ChatMessage(role: .assistant, content: chat.streamingText),
                            colorScheme: colorScheme
                        )
                        .id("streaming")
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.conversation.messages.count) { _ in
                scrollToEnd(proxy)
            }
            .onChange(of: chat.streamingText) { _ in
                scrollToEnd(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Howdy — I'm Minutes.")
                .font(.headline)
            Text("I keep watch while you work—app hops, finished builds, and nudges. Click me anytime, or just keep goin'.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Minutes…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
            if chat.isStreaming {
                Button("Stop") { chat.cancelStreaming() }
            } else {
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        draft = ""
        chat.send(text)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if !chat.streamingText.isEmpty {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = chat.conversation.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let colorScheme: ColorScheme

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(message.role == .user
                              ? MinutesTheme.userBubble(for: colorScheme)
                              : MinutesTheme.assistantBubble(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            Color.primary.opacity(message.role == .user ? 0 : (colorScheme == .dark ? 0.15 : 0.06)),
                            lineWidth: 1
                        )
                )
            if message.role != .user { Spacer(minLength: 40) }
        }
    }
}
