import AppKit
import SwiftUI
import MinutesCore

struct ChatPanelView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ChatPanelContent(chat: appModel.chatService, voice: appModel.voiceInput, coding: appModel.coding)
            .environmentObject(appModel)
            .preferredColorScheme(
                MinutesTheme.preferredColorScheme(for: appModel.settingsStore.settings.appearance)
            )
    }
}

private enum PanelTab: String, CaseIterable {
    case chat = "Chat"
    case tasks = "Tasks"
    case mind = "Mind"
    case memory = "Memory"
}

private struct ChatPanelContent: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var chat: ChatService
    @ObservedObject var voice: VoiceInputManager
    @ObservedObject var coding: CodingAgentRunner
    @State private var draft = ""
    @State private var tab: PanelTab = .chat
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Rectangle().fill(MinutesTheme.hairline(for: colorScheme)).frame(height: 1)
            switch tab {
            case .chat:
                messageList
                ForEach(coding.runningJobs) { job in
                    BackgroundJobRow(job: job, colorScheme: colorScheme)
                }
                statusStrip
                Rectangle().fill(MinutesTheme.hairline(for: colorScheme)).frame(height: 1)
                composer
            case .tasks:
                TasksTab(store: appModel.taskStore, reminders: appModel.reminderStore)
            case .mind:
                MindTab(goals: appModel.goalStore, thoughts: appModel.thoughts)
            case .memory:
                MemoryTab(store: appModel.memoryStore)
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .background(MinutesTheme.panelBackground(for: colorScheme))
        .onAppear { focused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            StatusOrb(mood: chat.mood, speaking: appModel.speech.isSpeaking)
            VStack(alignment: .leading, spacing: 1) {
                Text("Miss Minute")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                MinutesTheme.label(statusText)
                    .foregroundStyle(MinutesTheme.accent(for: colorScheme))
            }
            Spacer()
            if appModel.speech.isSpeaking {
                iconButton("speaker.slash", help: "Stop talking") { appModel.speech.stop() }
            }
            Menu {
                Button("Brief me") { appModel.briefMeNow() }
                Button("Clear conversation") { Task { await chat.clearHistory() } }
                Divider()
                Button("Settings…") { appModel.openSettingsRequested() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var statusText: String {
        if voice.isListening { return "Listening…" }
        let own = chat.isStreaming && chat.initiative == .selfDirected
        if let status = chat.activityStatus { return own ? "On my own · \(status)" : status }
        if own { return "Working on my own…" }
        switch chat.mood {
        case .thinking: return "Thinking…"
        case .working: return "Working…"
        case .talking where chat.isStreaming: return "Talking…"
        default:
            if let job = coding.runningJobs.last, let step = job.progress.currentStep {
                return "\(job.project): \(step)"
            }
            let s = appModel.settingsStore.settings
            return "\(s.provider.displayName) · \(s.model)"
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                        if let count = badge(for: item) {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(MinutesTheme.accent(for: colorScheme).opacity(0.25)))
                        }
                    }
                    .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(tab == item ? MinutesTheme.accent(for: colorScheme).opacity(0.18) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func badge(for item: PanelTab) -> Int? {
        let count: Int
        switch item {
        case .tasks: count = appModel.taskStore.openTasks.count
        case .mind: count = appModel.goalStore.open.count
        default: count = 0
        }
        return count > 0 ? count : nil
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.visibleMessages.isEmpty && chat.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(chat.visibleMessages) { message in
                        MessageRow(message: message, colorScheme: colorScheme)
                            .id(message.id)
                    }
                    if !chat.streamingText.isEmpty {
                        MessageRow(
                            message: ChatMessage(role: .assistant, content: chat.streamingText),
                            colorScheme: colorScheme
                        )
                        .id("streaming")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: chat.conversation.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: chat.streamingText) { _, _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Well hey there, sugar.")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("I keep your timeline tidy. Tell me what you're working on, what's due, or what to remember — I'll track it, remind you, and nudge you when it matters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach([
                    "Brief me on my day",
                    "I need to send the invoice by Friday 5pm",
                    "Start a 25 minute focus timer",
                    "Remember I take my coffee black"
                ], id: \.self) { suggestion in
                    Button {
                        chat.send(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "arrow.turn.down.right")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MinutesTheme.accent(for: colorScheme))
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusStrip: some View {
        if voice.isListening {
            HStack(spacing: 8) {
                LevelMeter(level: voice.level)
                Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button("Done") { voice.stop(deliver: true) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        if let error = chat.lastError ?? voice.errorMessage ?? appModel.speech.lastEngineError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Miss Minute…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                )
            iconButton(voice.isListening ? "waveform.circle.fill" : "mic.fill",
                       help: "Talk (\(appModel.settingsStore.settings.listenHotKey.displayString))") {
                appModel.toggleListening()
            }
            .foregroundStyle(voice.isListening ? MinutesTheme.accent(for: colorScheme) : Color.secondary)
            if chat.isStreaming {
                iconButton("stop.circle.fill", help: "Stop") { chat.cancelStreaming() }
            } else {
                iconButton("arrow.up.circle.fill", help: "Send (Return)") { send() }
                    .foregroundStyle(MinutesTheme.accent(for: colorScheme))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func send() {
        let text = draft
        draft = ""
        chat.send(text)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

// MARK: - Rows

private struct MessageRow: View {
    let message: ChatMessage
    let colorScheme: ColorScheme

    var body: some View {
        switch message.role {
        case .tool:
            ActionChip(text: message.displaySummary ?? "", colorScheme: colorScheme)
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(MinutesTheme.userBubble(for: colorScheme))
                    )
            }
        default:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if message.isProactive == true {
                        MinutesTheme.label("on her own")
                            .foregroundStyle(MinutesTheme.accent(for: colorScheme).opacity(0.8))
                    }
                    Text(Self.markdown(message.content))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(MinutesTheme.assistantBubble(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MinutesTheme.hairline(for: colorScheme), lineWidth: 1)
                )
                Spacer(minLength: 32)
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct ActionChip: View {
    let text: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(MinutesTheme.accent(for: colorScheme))
            Text(text)
                .lineLimit(2)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().strokeBorder(MinutesTheme.hairline(for: colorScheme), lineWidth: 1))
        .padding(.leading, 4)
    }
}

/// A live line for a coding job running in the background: what it's doing now, with its recent steps one click away.
private struct BackgroundJobRow: View {
    let job: CodingAgentRunner.Job
    let colorScheme: ColorScheme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        TimelineView(.periodic(from: job.startedAt, by: 1)) { timeline in
                            MinutesTheme.label("\(job.agent) · \(job.project) · \(Self.elapsed(since: job.startedAt, now: timeline.date))")
                                .foregroundStyle(MinutesTheme.accent(for: colorScheme))
                        }
                        Text(job.progress.currentStep ?? "Starting…")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentTransition(.opacity)
                            .animation(.easeOut(duration: 0.2), value: job.progress.currentStep)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to see her recent steps")

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(job.progress.recent(8)) { entry in
                        Text(CodingProgressLog.line(for: entry, since: job.startedAt))
                            .font(.system(size: 10.5, design: .monospaced))
                            .italic(entry.kind == .note)
                            .foregroundStyle(entry.kind == .problem ? Color.orange : Color.secondary)
                            .lineLimit(2)
                    }
                    if let log = job.logURL {
                        Button("Open full log") { NSWorkspace.shared.open(log) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(MinutesTheme.accent(for: colorScheme).opacity(colorScheme == .dark ? 0.08 : 0.06))
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct StatusOrb: View {
    let mood: CharacterMood
    let speaking: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let active = mood != .idle || speaking
            let pulse = active ? 0.75 + 0.25 * sin(t * 6) : 0.85 + 0.1 * sin(t * 1.5)
            ZStack {
                Circle().fill(MinutesTheme.amber.opacity(0.25 * pulse)).frame(width: 30, height: 30).blur(radius: 4)
                Circle()
                    .fill(RadialGradient(colors: [MinutesTheme.cream, MinutesTheme.amber], center: .topLeading, startRadius: 1, endRadius: 16))
                    .frame(width: 20, height: 20)
                    .opacity(pulse)
            }
        }
        .frame(width: 30, height: 30)
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(MinutesTheme.amber)
                    .frame(width: 3, height: 4 + CGFloat(level) * 14 * CGFloat([0.5, 0.8, 1, 0.8, 0.5][i]))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// MARK: - Tasks tab

private struct TasksTab: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var reminders: ReminderStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var newTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Open") {
                        if store.openTasks.isEmpty {
                            Text("Nothing on the timeline. Tell me what you need to do and I'll track it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(store.openTasks) { task in taskRow(task) }
                    }
                    if !reminders.upcoming.isEmpty {
                        section("Reminders & timers") {
                            ForEach(reminders.upcoming) { reminder in
                                HStack {
                                    Image(systemName: "bell").foregroundStyle(MinutesTheme.accent(for: colorScheme))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(reminder.text).font(.system(size: 12.5))
                                        Text(ToolDates.describe(reminder.fireAt)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        Task { await reminders.remove(id: reminder.id) }
                                    } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    let done = store.tasks.filter(\.isDone)
                    if !done.isEmpty {
                        section("Done recently") {
                            ForEach(done.prefix(10)) { task in taskRow(task) }
                        }
                    }
                }
                .padding(14)
            }
            Rectangle().fill(MinutesTheme.hairline(for: colorScheme)).frame(height: 1)
            HStack {
                TextField("Add a task…", text: $newTitle)
                    .textFieldStyle(.plain)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MinutesTheme.label(title).foregroundStyle(.secondary)
            content()
        }
    }

    private func taskRow(_ task: TrackedTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                Task { await store.setDone(id: task.id, !task.isDone) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Color.secondary : MinutesTheme.accent(for: colorScheme))
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
                HStack(spacing: 6) {
                    if let due = task.dueAt {
                        Label(ToolDates.describe(due), systemImage: "clock")
                            .foregroundStyle(task.isOverdue() ? Color.red : Color.secondary)
                    }
                    if task.priority == .high {
                        Label("High", systemImage: "flame").foregroundStyle(MinutesTheme.accent(for: colorScheme))
                    }
                }
                .font(.caption2)
            }
            Spacer()
            Button {
                Task { await store.remove(id: task.id) }
            } label: { Image(systemName: "trash").font(.caption) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newTitle = ""
        Task { await store.add(title: title) }
    }
}

// MARK: - Mind tab

/// Her independent thought process: how much she may do alone, the goals she's working through, and a live
/// stream of what she noticed, weighed, decided, and did.
private struct MindTab: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var goals: GoalStore
    @ObservedObject var thoughts: ThoughtLog
    @Environment(\.colorScheme) private var colorScheme
    @State private var newGoal = ""

    var body: some View {
        let level = appModel.settingsStore.settings.autonomyLevel
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        MinutesTheme.label("On my own").foregroundStyle(.secondary)
                        Picker("", selection: appModel.setting(\.autonomyLevel)) {
                            ForEach(AutonomyLevel.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(level.explanation).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MinutesTheme.label("Goals").foregroundStyle(.secondary)
                        if goals.open.isEmpty {
                            Text("No goals in progress. Give me something bigger below and I'll plan it and see it through.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(goals.open) { goal in GoalCard(goal: goal, store: goals, colorScheme: colorScheme) }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            MinutesTheme.label("Thoughts").foregroundStyle(.secondary)
                            Spacer()
                            Button("Open log") { NSWorkspace.shared.open(MinutesPaths.thoughtsLogURL) }
                                .buttonStyle(.borderless).font(.caption)
                                .disabled(!FileManager.default.fileExists(atPath: MinutesPaths.thoughtsLogURL.path))
                        }
                        if thoughts.thoughts.isEmpty {
                            Text(level == .off ? "I'm only acting when asked." : "Nothing on my mind yet. I look around every minute or so.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(thoughts.recent(60).reversed()) { thought in ThoughtRow(thought: thought, colorScheme: colorScheme) }
                    }
                }
                .padding(14)
            }
            Rectangle().fill(MinutesTheme.hairline(for: colorScheme)).frame(height: 1)
            HStack {
                TextField("Give her a goal… (e.g. get my Downloads organized)", text: $newGoal)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                Button("Go", action: submit)
                    .disabled(newGoal.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    private func submit() {
        let text = newGoal
        newGoal = ""
        appModel.pursueGoal(text)
    }
}

private struct GoalCard: View {
    let goal: Goal
    let store: GoalStore
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.objective).font(.system(size: 12.5, weight: .semibold))
                Text(goal.origin == .selfDirected ? "her idea" : "yours")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(MinutesTheme.accent(for: colorScheme).opacity(0.18)))
                Spacer()
                Button {
                    Task { await store.finish(id: goal.id, status: .abandoned, outcome: "Dropped by the user.") }
                } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Drop this goal")
            }
            ProgressView(value: Double(goal.settledCount), total: Double(max(1, goal.steps.count)))
                .tint(MinutesTheme.accent(for: colorScheme))
            ForEach(goal.steps) { step in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: Self.icon(step.status))
                        .foregroundStyle(Self.color(step.status, colorScheme))
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(.system(size: 11.5))
                            .foregroundStyle(step.status.isSettled ? Color.secondary : Color.primary)
                        if let note = step.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(MinutesTheme.accent(for: colorScheme).opacity(colorScheme == .dark ? 0.08 : 0.06)))
    }

    static func icon(_ status: Goal.Step.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .doing: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .failed: return "exclamationmark.circle"
        case .needsUser: return "hand.raised.circle"
        }
    }

    static func color(_ status: Goal.Step.Status, _ scheme: ColorScheme) -> Color {
        switch status {
        case .failed: return .red
        case .needsUser: return .orange
        case .done, .skipped: return .secondary
        case .pending, .doing: return MinutesTheme.accent(for: scheme)
        }
    }
}

private struct ThoughtRow: View {
    let thought: Thought
    let colorScheme: ColorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).font(.caption).frame(width: 14)
                .foregroundStyle(thought.kind == .heldBack ? Color.orange : MinutesTheme.accent(for: colorScheme))
            VStack(alignment: .leading, spacing: 1) {
                Text(thought.text).font(.system(size: 11.5)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(thought.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch thought.kind {
        case .noticed: return "eye"
        case .considered: return "scalemass"
        case .decided: return "lightbulb"
        case .acted: return "hand.tap"
        case .progress: return "checklist"
        case .heldBack: return "hand.raised"
        }
    }
}

// MARK: - Memory tab

private struct MemoryTab: View {
    @ObservedObject var store: MemoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MinutesTheme.label("What I know about you").foregroundStyle(.secondary)
                if store.items.isEmpty {
                    Text("Nothing yet. Tell me about yourself — your routines, people, preferences — and I'll remember.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.items.reversed()) { item in
                    HStack(alignment: .top) {
                        Text(item.category.capitalized)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MinutesTheme.amber)
                            .frame(width: 70, alignment: .leading)
                        Text(item.fact).font(.system(size: 12.5)).textSelection(.enabled)
                        Spacer()
                        Button {
                            Task { await store.forget(id: item.id) }
                        } label: { Image(systemName: "xmark").font(.caption) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }
}
