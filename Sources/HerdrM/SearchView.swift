import HerdrKit
import SwiftUI

/// Command-palette style search over agents, terminals, and spaces across all devices (⌘K).
struct SearchSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    enum Result: Identifiable {
        case agent(AppModel.AgentEntry)
        case terminal(AppModel.TerminalEntry)
        case space(AppModel.SpaceEntry)

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .terminal(let entry): return "terminal-\(entry.id)"
            case .space(let entry): return "space-\(entry.id)"
            }
        }
    }

    private var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let agents = model.devices.flatMap { device in
            model.session(device.id).agents.map { model.agentEntry(device: device, agent: $0) }
        }.filter { entry in
            q.isEmpty
                || entry.title.lowercased().contains(q)
                || entry.agent.title.lowercased().contains(q)
                || entry.agent.agent.lowercased().contains(q)
                || (entry.agent.name?.lowercased().contains(q) ?? false)
                || (entry.tabLabel?.lowercased().contains(q) ?? false)
                || (entry.agent.terminalTitleStripped ?? entry.agent.terminalTitle)?
                    .lowercased().contains(q) == true
                || entry.device.name.lowercased().contains(q)
                || model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID)
                    .lowercased().contains(q)
        }
        let spaces = model.devices.flatMap { device in
            model.session(device.id).workspaces.map { AppModel.SpaceEntry(device: device, workspace: $0) }
        }.filter { entry in
            q.isEmpty
                || entry.workspace.label.lowercased().contains(q)
                || entry.device.name.lowercased().contains(q)
        }
        let terminals = model.devices.flatMap { model.terminalEntries(for: $0) }.filter { entry in
            q.isEmpty
                || entry.title.lowercased().contains(q)
                || (entry.pane.cwd?.lowercased().contains(q) ?? false)
                || (entry.tab?.label.lowercased().contains(q) ?? false)
                || entry.device.name.lowercased().contains(q)
                || model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)
                    .lowercased().contains(q)
        }
        // Sidebar follows herdr tab order so drag-reorder sticks. ⌘K still
        // ranks by urgency: needs input, unread, working, then the rest.
        let ranked = agents.sorted {
            let r0 = searchRank($0)
            let r1 = searchRank($1)
            if r0 != r1 { return r0 < r1 }
            return ($0.agent.revision ?? 0) > ($1.agent.revision ?? 0)
        }
        return ranked.map(Result.agent) + terminals.map(Result.terminal) + spaces.map(Result.space)
    }

    private func searchRank(_ entry: AppModel.AgentEntry) -> Int {
        switch entry.agent.status {
        case .blocked: return 0
        case .done where model.isUnread(entry): return 1
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        case .unknown: return 5
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search agents, terminals, and spaces…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit { chooseHighlighted() }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            if results.isEmpty {
                Text("No matches")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                row(result, isHighlighted: index == highlighted)
                                    .onTapGesture { choose(result) }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 320)
                    // anchor: nil moves the minimum to reveal the row — a no-op when it
                    // is already visible, so hovering never yanks the scroll position.
                    .onChange(of: highlighted) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id, anchor: nil)
                    }
                    // Reopening ⌘K starts at the top even if the sheet was left
                    // scrolled to the bottom.
                    .onAppear {
                        if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 12) {
                KeyHint(key: "↑↓", label: "navigate")
                KeyHint(key: "↩", label: "open")
                Spacer()
                KeyHint(key: "esc", label: "cancel")
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .frame(width: 440)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    @ViewBuilder
    private func row(_ result: Result, isHighlighted: Bool) -> some View {
        HStack(spacing: 9) {
            switch result {
            case .agent(let entry):
                PaneRowLabel(model: model, entry: .agent(entry))
            case .terminal(let entry):
                PaneRowLabel(model: model, entry: .terminal(entry))
            case .space(let entry):
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(entry.workspace.label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                RowTrailing(
                    model: model,
                    text: String(localized: "Space · \(model.agentCount(in: entry)) agents"),
                    device: entry.device
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHighlighted ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
    }

    private func chooseHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        choose(results[highlighted])
    }

    private func choose(_ result: Result) {
        switch result {
        case .agent(let entry):
            model.reveal(entry.ref)
        case .terminal(let entry):
            model.reveal(entry.ref)
        case .space(let entry):
            if let filter = model.deviceFilter, filter != entry.device.id {
                model.setDeviceFilter(nil)
            }
            model.selectSpace(entry.ref)
        }
        dismiss()
    }
}
