import SwiftUI
import MinutesCore

struct ChatPanelView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ChatPanelContent(chat: appModel.chatService)
            .environmentObject(appModel)
    }
}

private struct ChatPanelContent: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var chat: ChatService
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let error = chat.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Divider()
            composer
        }
        .frame(minWidth: 320, minHeight: 400)
        .background(panelBackground)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Minutes")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(appModel.settingsStore.settings.provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if !chat.streamingText.isEmpty {
                        MessageBubble(
                            message: ChatMessage(role: .assistant, content: chat.streamingText)
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
            Text("Ask a question, or say “remind me in 20 minutes to stretch.”")
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

    private var panelBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.98, blue: 0.92),
                Color(red: 0.96, green: 0.93, blue: 0.84)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
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
                              ? Color(red: 0.85, green: 0.45, blue: 0.18)
                              : Color.white.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(message.role == .user ? 0 : 0.06), lineWidth: 1)
                )
            if message.role != .user { Spacer(minLength: 40) }
        }
    }
}
