import AppKit
import HerdrKit
import SwiftUI

struct ConversationHistoryDrawer: View {
    @ObservedObject var controller: ConversationHistoryController
    @FocusState private var searchFocused: Bool
    @State private var showingTurns = false
    @State private var copyTask: Task<Void, Never>?
    @State private var copyingMessageID: String?
    @State private var readTask: Task<Void, Never>?
    @State private var readingMessageID: String?
    @State private var fullMessage: ConversationMessage?
    @State private var copyError: String?
    @State private var lastScrolledID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Divider()
            if let error = copyError {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger)
                    Spacer()
                    Button("Dismiss") { copyError = nil }.buttonStyle(.plain)
                }.padding(10)
            }
            if copyingMessageID != nil || readingMessageID != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading complete message…").font(.system(size: 11))
                    Spacer()
                    Button("Cancel") { cancelCopy(); cancelRead() }.controlSize(.small)
                        .accessibilityIdentifier("history.cancelLoading")
                }.padding(10)
            }
            if showingTurns {
                turnIndex
            } else {
                conversation
            }
            Divider()
            HStack(spacing: 12) {
                Button { controller.previousTurn() } label: { Label("Previous turn", systemImage: "arrow.up") }
                    .accessibilityIdentifier("history.previousTurn")
                Button { controller.nextTurn() } label: { Label("Next turn", systemImage: "arrow.down") }
                    .accessibilityIdentifier("history.nextTurn")
                Spacer(minLength: 0)
            }.buttonStyle(.plain).font(.system(size: 11)).padding(10)
        }
        .background(Theme.contentBackground)
        .foregroundStyle(Theme.text)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.sidebarBorder).frame(width: 1) }
        .onExitCommand { controller.close() }
        .onKeyPress(.escape) { controller.close(); return .handled }
        .onDisappear { cancelCopy(); cancelRead() }
        .onChange(of: controller.messages.isEmpty) { _, empty in
            if empty { cancelRead(); fullMessage = nil }
        }
        .onChange(of: controller.messages) { _, messages in
            if let fullMessage,
               !messages.contains(where: { $0.id == fullMessage.id && $0.messageRevision == fullMessage.messageRevision }) {
                self.fullMessage = nil
            }
        }
        .sheet(item: $fullMessage) { message in
            VStack(spacing: 0) {
                HStack {
                    Text("Full message").font(.headline)
                    Spacer()
                    Button("Close") { fullMessage = nil }
                        .accessibilityIdentifier("history.fullMessage.close")
                }.padding(14)
                Divider()
                if copyingMessageID != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading complete message…").font(.system(size: 11))
                        Spacer()
                        Button("Cancel") { cancelCopy() }
                    }.padding(12)
                }
                ScrollView {
                    ConversationMessageView(message: message) { copy(message.id) }.padding(14)
                }
            }
            .frame(minWidth: 360, idealWidth: 560, maxWidth: 720, minHeight: 300, idealHeight: 560)
            .background(Theme.contentBackground)
            .onExitCommand { fullMessage = nil }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("history.fullMessage")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.drawer")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Conversation history").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button { showingTurns.toggle() } label: { Image(systemName: showingTurns ? "text.bubble" : "list.number") }
                .help(showingTurns ? String(localized: "Conversation") : String(localized: "All turns"))
                .accessibilityLabel(showingTurns ? String(localized: "Conversation") : String(localized: "All turns"))
                .accessibilityIdentifier("history.allTurns")
            Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                .help("Search conversation").accessibilityLabel("Search conversation")
                .keyboardShortcut("f", modifiers: .command)
            Button { controller.close() } label: { Image(systemName: "xmark") }
                .help("Close history").accessibilityLabel("Close history")
                .accessibilityIdentifier("history.close")
        }.buttonStyle(.plain).padding(12)
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search saved conversation…", text: $controller.searchQuery)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onChange(of: controller.searchQuery) { _, query in controller.search(query) }
                    .onSubmit { moveMatch(1) }
                    .accessibilityIdentifier("history.search")
                if !controller.searchQuery.isEmpty {
                    Button { controller.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            if !controller.searchQuery.isEmpty {
                HStack {
                    Text(controller.matchedMessageIDs.isEmpty ? String(localized: "No matches") : String(localized: "\(controller.matchedMessageIDs.count) matches"))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button { moveMatch(-1) } label: { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Previous match")
                    Button { moveMatch(1) } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Next match")
                }.buttonStyle(.plain).disabled(controller.matchedMessageIDs.isEmpty)
            }
        }.font(.system(size: 11)).padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var turnIndex: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if controller.turns.isEmpty {
                    Text("No saved user turns").foregroundStyle(Theme.textTertiary).padding(12)
                }
                ForEach(controller.turns, id: \.id) { turn in
                    Button {
                        showingTurns = false
                        controller.open(turnID: turn.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Turn \(turn.ordinal)").font(.system(size: 11, weight: .medium))
                                if let timestamp = turn.timestamp { Text(timestamp).font(.system(size: 10)).foregroundStyle(Theme.textTertiary) }
                            }
                            Text(verbatim: turn.preview).font(.system(size: 12)).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(controller.selectedMessageID == turn.messageID ? Theme.accentWash : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("history.turn.\(turn.id)")
                }
            }.padding(8)
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if let quality = ConversationHistoryNotice.quality(for: controller.completeness) {
                stateNotice(quality, symbol: "info.circle")
                    .accessibilityIdentifier("history.sourceQuality")
            }
            if !controller.messages.isEmpty {
                if case .failed(let reason) = controller.state { stateNotice(reason, symbol: "exclamationmark.triangle") }
                if case .unavailable(let reason) = controller.state { stateNotice(reason, symbol: "clock.badge.exclamationmark") }
            }
            if controller.hasNewMessages {
                Button {
                    showingTurns = false
                    lastScrolledID = nil
                    controller.showLatest()
                } label: { Label("New messages", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent).padding(10)
                    .accessibilityIdentifier("history.newMessages")
            }
            if controller.messages.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if controller.canLoadOlder {
                                Button { controller.loadOlder() } label: {
                                    HStack {
                                        if controller.isLoadingOlder { ProgressView().controlSize(.small) }
                                        Text("Load older messages")
                                    }
                                }.disabled(controller.isLoadingOlder).accessibilityIdentifier("history.older")
                            }
                            ForEach(controller.messages, id: \.id) { message in
                                ConversationMessageView(message: message, readFullAction: { readComplete(message.id) }) { copy(message.id) }
                                    .disabled(controller.copyInProgress)
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(controller.selectedMessageID == message.id ? Theme.accent : .clear, lineWidth: 1))
                                    .id(message.id)
                            }
                            if controller.canLoadNewer {
                                Button { controller.loadNewer() } label: {
                                    HStack {
                                        if controller.isLoadingNewer { ProgressView().controlSize(.small) }
                                        Text("Load newer messages")
                                    }
                                }.disabled(controller.isLoadingNewer).accessibilityIdentifier("history.newer")
                            }
                        }.padding(12)
                    }
                    .background(ConversationScrollObserver {
                        // User scrolling opts out of automatic latest-message selection.
                        // Selecting an already-loaded ID performs no read or terminal RPC.
                        if let id = controller.selectedMessageID,
                           controller.messages.contains(where: { $0.id == id }) {
                            controller.selectMessage(id)
                        }
                    })
                    .onAppear {
                        if controller.selectedMessageID == nil, let last = controller.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        } else { scrollSelection(proxy) }
                    }
                    .onChange(of: controller.selectedMessageID) { _, _ in scrollSelection(proxy) }
                    .onChange(of: controller.messages.map(\.id)) { _, _ in scrollSelection(proxy) }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch controller.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading saved conversation…").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        case .ready:
            stateNotice(String(localized: "No saved messages yet"), symbol: "text.bubble")
        case .unavailable(let reason):
            stateNotice(reason, symbol: "clock.badge.exclamationmark")
        case .failed(let reason):
            VStack {
                stateNotice(reason, symbol: "exclamationmark.triangle")
                Button("Try again") { controller.refresh() }.controlSize(.small)
            }
        }
    }

    private func stateNotice(_ text: String, symbol: String) -> some View {
        Label(ConversationHistoryNotice.text(for: text), systemImage: symbol).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true).padding(16)
    }

    private func scrollSelection(_ proxy: ScrollViewProxy) {
        guard let id = controller.selectedMessageID, id != lastScrolledID,
              controller.messages.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id, anchor: .top)
        lastScrolledID = id
    }

    private func moveMatch(_ delta: Int) {
        let ids = controller.matchedMessageIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: controller.selectedMessageID ?? "") ?? (delta > 0 ? -1 : 0)
        let index = (current + delta + ids.count) % ids.count
        showingTurns = false
        controller.selectMessage(ids[index])
    }

    private func copy(_ id: String) {
        cancelRead()
        cancelCopy()
        copyingMessageID = id
        copyError = nil
        copyTask = Task { @MainActor in
            do {
                let text = try await controller.copyText(messageID: id)
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { copyError = String(localized: "Could not copy the complete message. \(error.localizedDescription)") }
            }
            if !Task.isCancelled { copyingMessageID = nil; copyTask = nil }
        }
    }

    private func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        copyingMessageID = nil
    }

    private func readComplete(_ id: String) {
        cancelCopy()
        cancelRead()
        readingMessageID = id
        copyError = nil
        readTask = Task { @MainActor in
            do {
                let message = try await controller.completeMessage(messageID: id)
                try Task.checkCancellation()
                fullMessage = message
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { copyError = String(localized: "Could not load the complete message. \(error.localizedDescription)") }
            }
            if !Task.isCancelled { readingMessageID = nil; readTask = nil }
        }
    }

    private func cancelRead() {
        readTask?.cancel()
        readTask = nil
        readingMessageID = nil
    }
}

enum ConversationHistoryNotice {
    static func quality(for completeness: String) -> String? {
        switch completeness {
        case "source_available", "": return nil
        case "partial_unsupported_records": return String(localized: "Some saved records could not be displayed.")
        case "partial_trailing_record": return String(localized: "The latest message is still being saved.")
        default: return String(localized: "Some saved conversation records are unavailable.")
        }
    }
    static func text(for reason: String) -> String {
        switch reason {
        case "unsupported_server": return String(localized: "Update herdr on this device to read saved conversation history.")
        case "unsupported_device": return String(localized: "Saved conversation history is not available for this device.")
        case "loading": return String(localized: "Loading the saved conversation…")
        case "no_binding", "missing_binding", "unbound": return String(localized: "No saved conversation is linked to this Claude session.")
        case "missing", "missing_source", "source_missing", "deleted", "source_deleted": return String(localized: "The saved conversation is no longer available on this device.")
        case "not_recorded": return String(localized: "No saved transcript was recorded for this Claude session.")
        case "persistence_disabled", "disabled": return String(localized: "Claude conversation saving is disabled.")
        case "retention_expired", "expired": return String(localized: "This saved conversation has expired.")
        case "access_denied", "permission_denied", "source_unreadable": return String(localized: "Herdrm does not have permission to read this saved conversation.")
        case "unsupported_format", "unsupported_schema": return String(localized: "This Claude conversation format is not supported yet.")
        case "session_changed": return String(localized: "The Claude session changed. Select the agent again to reload history.")
        case "disconnected": return String(localized: "Reconnect this device to read saved conversation history.")
        default: return reason
        }
    }
}

/// Observes scroll-wheel input only inside the drawer's scroll viewport. Returning
/// the event untouched preserves native scrolling and terminal first responders.
private struct ConversationScrollObserver: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> ScrollObserverView { ScrollObserverView(onScroll: onScroll) }
    func updateNSView(_ view: ScrollObserverView, context: Context) { view.onScroll = onScroll }

    final class ScrollObserverView: NSView {
        var onScroll: () -> Void
        private var monitor: Any?
        init(onScroll: @escaping () -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                   self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onScroll()
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
