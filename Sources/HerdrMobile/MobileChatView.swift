import HerdrKit
import SwiftUI

/// An agent on the phone: Chat (the default) or its live Terminal. Real work
/// happens in agents, and a TUI on a narrow screen with a tiny input is hard
/// going, so the chat is how the phone drives the agent; the terminal is one tap away.
struct MobileAgentDetailView: View {
    enum Mode: Hashable {
        case chat
        case terminal
    }

    let transport: MobileTransport
    let agent: AgentInfo
    let title: String
    /// tailcat carries herdr's control plane only, so there is no terminal to attach.
    let terminalAvailable: Bool

    @State private var mode: Mode = .chat
    @StateObject private var chat: MobileAgentChatModel

    init(transport: MobileTransport, agent: AgentInfo, title: String, terminalAvailable: Bool,
         chat: MobileAgentChatModel? = nil) {
        self.transport = transport
        self.agent = agent
        self.title = title
        self.terminalAvailable = terminalAvailable
        _chat = StateObject(wrappedValue: chat ?? MobileAgentChatModel(transport: transport, agent: agent))
    }

    var body: some View {
        Group {
            switch mode {
            case .chat:
                MobileChatView(model: chat, title: title, openTerminal: { mode = .terminal })
            case .terminal:
                if terminalAvailable {
                    // Attaches with --takeover, so it only runs while this tab is shown.
                    MobileTerminalScreen(transport: transport, target: .agent(paneID: agent.paneID),
                                         paneID: agent.paneID, title: title)
                } else {
                    ContentUnavailableView(
                        String(localized: "No Terminal over Tailcat"),
                        systemImage: "terminal",
                        description: Text(String(localized: "This device's tunnel reaches herdr's control plane only. Use an SSH device to attach to a live terminal."))
                    )
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(String(localized: "View"), selection: $mode) {
                    Text(String(localized: "Chat")).tag(Mode.chat)
                    Text(String(localized: "Terminal")).tag(Mode.terminal)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .accessibilityLabel(String(localized: "Agent view"))
            }
        }
        .onChange(of: agent.status) { _, status in chat.update(status: status) }
    }
}

struct MobileChatView: View {
    @ObservedObject var model: MobileAgentChatModel
    let title: String
    let openTerminal: () -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            content
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var statusBar: some View {
        let model = self.model
        let interrupt: (() -> Void)? = model.status == .working ? { model.interrupt() } : nil
        return ChatStatusBar(status: model.status, agentName: model.kind?.displayName, onInterrupt: interrupt)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                NoticeBanner(text: notice) { model.notice = nil }
            }
            choiceCard
            composer
        }
        .animation(.snappy, value: model.choice?.fingerprint)
    }

    @ViewBuilder
    private var choiceCard: some View {
        if let choice = model.choice, model.kind != nil {
            let model = self.model
            ChoiceCard(
                choice: choice,
                pendingCall: model.pendingToolCall,
                answering: model.answering,
                onChoose: { option, text in model.choose(option, text: text) },
                onSubmit: { model.submit() },
                onCancel: { model.cancelChoice() },
                openTerminal: openTerminal
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .ready:
            transcript
        case .loading:
            ProgressView(String(localized: "Loading conversation…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            fallback
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.items.isEmpty && model.outgoing.isEmpty {
                    Text(String(localized: "No messages yet. Send the agent a prompt below."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                ForEach(model.items) { item in
                    ChatRow(item: item, agentName: model.kind?.displayName ?? "")
                        .id(item.id)
                }
                ForEach(Array(model.outgoing.enumerated()), id: \.offset) { _, text in
                    UserBubble(text: text, attachments: 0, sending: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    private var fallback: some View {
        let (heading, detail): (String, String) = {
            switch model.availability {
            case .unsupportedAgent:
                return (String(localized: "Chat isn't available for this agent"),
                        String(localized: "Herdrm can show Claude Code and Codex conversations. Use the terminal for this one."))
            case .noSession:
                return (String(localized: "No conversation to show yet"),
                        String(localized: "herdr hasn't reported this agent's session. Its official herdr integration reports it once the agent starts a conversation."))
            case .noShell:
                return (String(localized: "Conversation needs SSH"),
                        String(localized: "Reading the conversation needs a shell on the device. Choices and prompts still work here."))
            case .missing:
                return (String(localized: "Conversation not found"),
                        String(localized: "The agent's transcript isn't on this device yet."))
            case .failed(let reason):
                return (String(localized: "Couldn't read the conversation"), reason)
            case .ready, .loading:
                return ("", "")
            }
        }()
        return ContentUnavailableView {
            Label(heading, systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text(detail)
        } actions: {
            Button(String(localized: "Open Terminal"), action: openTerminal)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Message the agent…"), text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(.separator).opacity(0.6), lineWidth: 0.5))
                .accessibilityLabel(String(localized: "Message"))
            Button {
                model.sendPrompt(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.accentColor : Color(.systemGray3), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel(String(localized: "Send message"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

// MARK: - Status

private struct ChatStatusBar: View {
    let status: AgentStatus
    let agentName: String?
    let onInterrupt: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint)
            Spacer()
            if let onInterrupt {
                Button(String(localized: "Stop"), systemImage: "stop.fill", action: onInterrupt)
                    .labelStyle(.titleAndIcon)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.secondary)
                    .accessibilityLabel(String(localized: "Stop the agent"))
                    .accessibilityHint(String(localized: "Sends Escape to interrupt the current turn."))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .working: ProgressView().controlSize(.mini)
        case .blocked: Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.footnote)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case .idle, .unknown: Circle().fill(Color(.systemGray3)).frame(width: 8, height: 8)
        }
    }

    private var label: String {
        let name = agentName ?? String(localized: "Agent")
        switch status {
        case .working: return String(localized: "\(name) is working…")
        case .blocked: return String(localized: "\(name) needs your input")
        case .done: return String(localized: "\(name) finished")
        case .idle: return String(localized: "\(name) is idle")
        case .unknown: return name
        }
    }

    private var tint: Color {
        switch status {
        case .blocked: return .orange
        default: return .secondary
        }
    }
}

private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// MARK: - Rows

private struct ChatRow: View {
    let item: AgentChatItem
    let agentName: String

    var body: some View {
        switch item.content {
        case .user(let text, let attachments):
            UserBubble(text: text, attachments: attachments, sending: false)
        case .assistant(let text):
            AssistantText(text: text)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "\(agentName): \(text)"))
        case .tool(let call):
            switch call.special {
            case .questions(let questions): QuestionsCard(call: call, questions: questions)
            case .plan(let plan): PlanCard(call: call, plan: plan)
            case nil: ToolCallRow(call: call)
            }
        case .notice(let text):
            HStack {
                Spacer()
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
}

private struct UserBubble: View {
    let text: String
    let attachments: Int
    let sending: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                }
                if attachments > 0 {
                    Label(String(localized: "\(attachments) attachment(s)"), systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.accentColor, in: BubbleShape())
            .opacity(sending ? 0.6 : 1)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sending
            ? String(localized: "You, sending: \(text)")
            : String(localized: "You: \(text)"))
    }
}

/// A rounded bubble with a tighter bottom-trailing corner.
private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, bottomLeading: 18, bottomTrailing: 6, topTrailing: 18))
            .path(in: rect)
    }
}

/// Markdown-ish rendering: fenced code blocks, headings, list items, and inline
/// markdown (bold, italics, code, links) through AttributedString.
private struct AssistantText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                case .heading(let line):
                    Text(MarkdownBlock.inline(line)).font(.headline)
                case .paragraph(let line):
                    Text(MarkdownBlock.inline(line))
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case code(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                paragraph.append("•  " + trimmed.dropFirst(2))
                continue
            }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct ToolCallRow: View {
    let call: AgentChatToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: ToolGlyph.symbol(for: call.name))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ToolGlyph.title(for: call.name))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let summary = call.summary {
                            Text(summary)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    ToolStateMark(state: call.state)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityHint(String(localized: "Shows the tool's input and result."))

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = call.input {
                        CodePane(title: String(localized: "Input"), text: input)
                    }
                    if let result = call.result {
                        CodePane(title: String(localized: "Result"), text: result)
                    }
                    if call.input == nil && call.result == nil {
                        Text(String(localized: "No details")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var accessibilityTitle: String {
        let state: String = switch call.state {
        case .pending: String(localized: "running")
        case .succeeded: String(localized: "done")
        case .failed: String(localized: "failed")
        case .rejected: String(localized: "declined")
        }
        return "\(ToolGlyph.title(for: call.name)), \(call.summary ?? ""), \(state)"
    }
}

private struct CodePane: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(40)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ToolStateMark: View {
    let state: AgentChatToolCall.State

    var body: some View {
        switch state {
        case .pending: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.red)
        case .rejected: Image(systemName: "hand.raised.slash").font(.caption.weight(.semibold)).foregroundStyle(.orange)
        }
    }
}

enum ToolGlyph {
    static func symbol(for name: String) -> String {
        switch name.lowercased() {
        case "bash", "shell", "exec", "exec_command", "local_shell", "bashoutput", "killshell": return "terminal"
        case "read", "notebookread": return "doc.text"
        case "edit", "multiedit", "notebookedit", "apply_patch": return "pencil"
        case "write": return "square.and.pencil"
        case "grep", "glob", "toolsearch": return "magnifyingglass"
        case "webfetch", "websearch", "web_search": return "globe"
        case "agent", "task": return "person.2"
        case "todowrite", "taskcreate", "taskupdate", "update_plan": return "checklist"
        case "skill": return "wand.and.stars"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// `mcp__server__tool` reads as "server · tool".
    static func title(for name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.joined(separator: " · ")
    }
}

private struct QuestionsCard: View {
    let call: AgentChatToolCall
    let questions: [AgentChatQuestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "Question"), systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.subheadline.weight(.semibold))
                    if let answer = call.answers[question.question] {
                        Label(answer, systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(question.options.map(\.label).joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if call.state == .rejected {
                Text(String(localized: "Dismissed")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PlanCard: View {
    let call: AgentChatToolCall
    let plan: String
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Label(String(localized: "Plan"), systemImage: "list.bullet.clipboard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Plan, \(stateLabel)"))
            .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            if expanded {
                AssistantText(text: plan)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
    }

    private var stateLabel: String {
        switch call.state {
        case .pending: return String(localized: "Awaiting approval")
        case .succeeded: return String(localized: "Approved")
        case .rejected, .failed: return String(localized: "Not approved")
        }
    }
}

// MARK: - Choice card

/// The question the agent is blocked on, with one button per option. Tapping
/// sends the keys its TUI expects; options that take words open a text field.
private struct ChoiceCard: View {
    let choice: AgentPendingChoice
    let pendingCall: AgentChatToolCall?
    let answering: MobileAgentChatModel.Answering?
    let onChoose: (AgentPendingChoice.Option, String?) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let openTerminal: () -> Void

    @State private var textOption: Int?
    @State private var text = ""
    @State private var showContext = false
    @FocusState private var textFocused: Bool

    private var busy: Bool { answering != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                Text(String(localized: "Needs your input"))
                Spacer()
                if case .waiting = answering {
                    ProgressView().controlSize(.mini)
                    Text(String(localized: "Sent")).foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

            Text(choice.question.isEmpty ? String(localized: "The agent is waiting for your choice.") : choice.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let detail = contextText {
                Button {
                    withAnimation(.snappy) { showContext.toggle() }
                } label: {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(showContext ? 30 : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Details: \(detail)"))
                .accessibilityValue(showContext ? String(localized: "Expanded") : String(localized: "Collapsed"))
            }

            // A ScrollView takes all the height it is offered, so only long
            // lists get one.
            if choice.options.count > 5 || choice.options.contains(where: { $0.detail != nil && choice.options.count > 3 }) {
                ScrollView {
                    optionList
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: 300)
            } else {
                optionList
            }

            HStack(spacing: 10) {
                if choice.isMultiSelect {
                    Button(choice.submitLabel ?? String(localized: "Submit"), action: onSubmit)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        .accessibilityLabel(String(localized: "Submit the selected options"))
                }
                if choice.canCancel {
                    Button(String(localized: "Dismiss"), role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                        .disabled(busy)
                        .accessibilityLabel(String(localized: "Dismiss the question"))
                        .accessibilityHint(String(localized: "Sends Escape to the agent."))
                }
                Spacer()
                Button(String(localized: "Terminal"), systemImage: "terminal", action: openTerminal)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .accessibilityLabel(String(localized: "Open the terminal"))
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .onChange(of: choice.fingerprint) { _, _ in
            textOption = nil
            text = ""
        }
    }

    private var optionList: some View {
        VStack(spacing: 6) {
            ForEach(choice.options) { option in
                optionRow(option)
            }
        }
    }

    /// The transcript's view of what is asked (the full command) beats the
    /// few screen lines above the question.
    private var contextText: String? {
        if let call = pendingCall, call.special == nil, let input = call.input, !input.isEmpty {
            return input
        }
        let lines = choice.context.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func optionRow(_ option: AgentPendingChoice.Option) -> some View {
        let sending = answering == .sending(option.number)
        VStack(spacing: 6) {
            Button {
                if option.acceptsText {
                    textOption = textOption == option.number ? nil : option.number
                    textFocused = textOption != nil
                } else {
                    onChoose(option, nil)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    badge(option)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        if let detail = option.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    if sending {
                        ProgressView().controlSize(.small)
                    } else if option.acceptsText {
                        Image(systemName: "text.cursor").foregroundStyle(.secondary).font(.footnote)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(option.isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel(optionAccessibilityLabel(option))
            .accessibilityValue(option.isChecked.map { $0 ? String(localized: "Selected") : String(localized: "Not selected") } ?? "")
            .accessibilityHint(option.acceptsText
                ? String(localized: "Opens a text field for your answer.")
                : option.isChecked != nil ? String(localized: "Toggles this option.") : String(localized: "Sends this answer to the agent."))

            if textOption == option.number {
                HStack(spacing: 8) {
                    TextField(String(localized: "Your answer…"), text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($textFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(String(localized: "Answer for \(option.label)"))
                    Button {
                        onChoose(option, text)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(String(localized: "Send answer"))
                }
            }
        }
    }

    @ViewBuilder
    private func badge(_ option: AgentPendingChoice.Option) -> some View {
        if let checked = option.isChecked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.body)
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .frame(width: 24, height: 24)
        } else {
            Text("\(option.number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(option.isFocused ? .white : .secondary)
                .frame(width: 24, height: 24)
                .background(option.isFocused ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
        }
    }

    private func optionAccessibilityLabel(_ option: AgentPendingChoice.Option) -> String {
        var label = String(localized: "Option \(option.number): \(option.label)")
        if let detail = option.detail { label += ". \(detail)" }
        return label
    }
}
