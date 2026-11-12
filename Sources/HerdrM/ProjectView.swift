import HerdrKit
import SwiftUI

/// What the polling task depends on; a change restarts the loop (and so probes at once).
struct ProjectTaskKey: Equatable {
    var space: SpaceRef?
    var context: ProjectContext?
    var active: Bool
}

/// The per-Space "Project" pane that covers the terminal in `DetailMode.project`.
/// Read-only apart from the small override controls: URLs, hiding, attaching and the root.
struct ProjectView: View {
    @ObservedObject var model: AppModel
    /// Off in tests that inject a snapshot and must not probe.
    var polling = true
    @State private var windowVisible = false
    @State private var appActive = NSApp?.isActive ?? true

    private var taskKey: ProjectTaskKey {
        let space = model.projectSpace
        return ProjectTaskKey(
            space: space, context: space.flatMap { model.projectContext(for: $0) },
            active: polling && model.detailMode == .project && windowVisible && appActive)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.contentBackground)
            .background(WindowVisibilityReader(isVisible: $windowVisible))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
            .task(id: taskKey) {
                let key = taskKey
                guard key.active, let space = key.space, let context = key.context else { return }
                await model.projects.run(space: space, context: context)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let space = model.projectSpace {
            if let context = model.projectContext(for: space) {
                ProjectPanel(model: model, projects: model.projects, space: space, context: context)
                    .id(space)
            } else {
                ContentUnavailableView(
                    "Space not available", systemImage: "shippingbox",
                    description: Text("This Space is not reachable right now."))
            }
        } else {
            ContentUnavailableView(
                "No Space selected", systemImage: "shippingbox",
                description: Text("Select a Space to see its project."))
        }
    }
}

/// The pane for one Space: header, state handling and the sections.
private struct ProjectPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var projects: ProjectInspectorModel
    let space: SpaceRef
    let context: ProjectContext

    /// Disclosure cards ("other", "otherCompose", "hidden"); all collapsed by default.
    @State private var expanded: Set<String> = []
    @State private var refreshing = false
    @State private var changingRoot = false
    @State private var rootText = ""
    @State private var rootError: String?
    @State private var confirmingReset = false

    private var entry: ProjectInspectorModel.Entry? { projects.entry(for: space) }
    private var snapshot: ProjectSnapshot? { entry?.snapshot }
    private var isProbing: Bool { refreshing || entry?.state == .probing }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let rootError { errorBanner(rootError, showsStale: false) }
            if !ProjectProbeScript.isSupported(context.device) {
                ContentUnavailableView(
                    "Project details unavailable", systemImage: "shippingbox",
                    description: Text("Project details need a shell, so tailcat and Windows devices are not supported."))
            } else if let snapshot {
                loaded(snapshot)
            } else {
                empty
            }
        }
        .confirmationDialog(
            "Reset overrides for \(snapshot?.identity.name ?? context.workspaceLabel)?",
            isPresented: $confirmingReset
        ) {
            Button("Reset overrides", role: .destructive) { projects.resetOverrides(space: space) }
        } message: {
            Text("This clears URLs, hidden listeners, attachments and linked hosts for this project.")
        }
        .alert("Change project root", isPresented: $changingRoot) {
            TextField("Absolute path on \(context.device.name)", text: $rootText)
            Button("Change") { applyRoot(rootText) }
            Button("Use Automatic Root") {
                rootError = nil
                projects.setRoot(space: space, context: context, root: nil)
            }
            Button("Cancel", role: .cancel) { rootError = nil }
        } message: {
            Text("Pin the folder this Space's project lives in.")
        }
    }

    // MARK: - States

    @ViewBuilder
    private var empty: some View {
        if case .failed(let message) = entry?.state {
            ContentUnavailableView {
                Label("No project found", systemImage: "shippingbox")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Refresh", action: refresh)
                Button("Change root…", action: beginChangingRoot)
            }
        } else if context.cwds.isEmpty {
            ContentUnavailableView(
                "No panes yet", systemImage: "terminal",
                description: Text("Open a terminal or agent in this Space to find its project."))
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Inspecting project…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loaded(_ snapshot: ProjectSnapshot) -> some View {
        VStack(spacing: 0) {
            if case .failed(let message) = entry?.state { errorBanner(message) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: ProjectMetrics.cardSpacing) {
                        ProjectOverviewCard(
                            topology: ProjectTopology.make(snapshot: snapshot, device: context.device, linked: linkedHosts),
                            scrollTo: { id in withAnimation { proxy.scrollTo(id, anchor: .top) } })
                        hotReloadSection(snapshot)
                        dockerSection(snapshot)
                        hostsSection(snapshot)
                        linksSection(snapshot)
                        filesSection(snapshot)
                        otherListenersSection(snapshot)
                        hiddenSection(snapshot)
                        ProjectWarningsFootnote(warnings: snapshot.warnings)
                    }
                    .padding(.horizontal, ProjectMetrics.pagePadding)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func errorBanner(_ message: String, showsStale: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(verbatim: message).foregroundStyle(Theme.text).lineLimit(2)
            if showsStale { Text("Showing the last result.").foregroundStyle(Theme.textSecondary) }
            Spacer()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.warning.opacity(0.12))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            titleRow
            if let snapshot {
                ProjectSummaryStrip(snapshot: snapshot, linkedHostCount: projects.linkedDevices(for: space).count)
                    .padding(.horizontal, 14)
                    .frame(height: 22)
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            ProjectKindTile(symbol: "shippingbox", tint: Theme.accent)
            Text(verbatim: snapshot?.identity.name ?? context.workspaceLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            DeviceChip(device: context.device)
            if let root = snapshot?.identity.root {
                Text(verbatim: (root as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if snapshot?.partial == true { ProjectTag("partial", tint: Theme.warning) }
            Spacer(minLength: 8)
            if let probed = entry?.lastProbe { updatedLabel(probed) }
            rootPicker
            Button(action: refresh) {
                if isProbing {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
            .disabled(isProbing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            optionsMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private func updatedLabel(_ date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let ago = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: max(timeline.date, date))
            Text("Updated \(ago)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    /// Other git roots the Space's panes sit in, when there are several to pick between.
    @ViewBuilder
    private var rootPicker: some View {
        let roots = candidateRoots
        if roots.count > 1 {
            Menu {
                ForEach(roots, id: \.self) { root in
                    Button {
                        projects.setRoot(space: space, context: context, root: root)
                    } label: {
                        if root == snapshot?.identity.root { Label(root, systemImage: "checkmark") } else { Text(verbatim: root) }
                    }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch project root")
            .accessibilityLabel("Project root")
        }
    }

    private var candidateRoots: [String] {
        var seen = Set<String>()
        return (entry?.rawProbe?.roots ?? []).compactMap(\.toplevel).filter { seen.insert($0).inserted }
    }

    private var optionsMenu: some View {
        Menu {
            Button("Change root…", action: beginChangingRoot)
            Menu("Link host…") {
                let hosts = linkableHosts
                if hosts.isEmpty {
                    Text("No other SSH hosts")
                } else {
                    ForEach(hosts) { host in
                        Button(host.name) {
                            if let root = snapshot?.identity.root {
                                projects.linkDevice(space: space, device: host, root: root)
                            }
                        }
                        .disabled(snapshot == nil)
                    }
                }
            }
            Divider()
            Button("Reset overrides", role: .destructive) { confirmingReset = true }
                .disabled(snapshot == nil)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project options")
        .accessibilityLabel("Project options")
    }

    /// Devices linked to this project, resolved through the app model.
    private var linkedHosts: [(device: Device, root: String)] {
        projects.linkedDevices(for: space).compactMap { link in
            model.device(link.deviceID).map { (device: $0, root: link.root) }
        }
    }

    /// Other SSH devices that are not linked to this project yet.
    private var linkableHosts: [Device] {
        let linked = Set(projects.linkedDevices(for: space).map(\.deviceID))
        return model.devices.filter { $0.sshTarget != nil && $0.id != context.device.id && !linked.contains($0.id) }
    }

    // MARK: - Actions

    private func refresh() {
        refreshing = true
        Task {
            _ = await projects.probe(space: space, context: context)
            refreshing = false
        }
    }

    private func beginChangingRoot() {
        rootText = snapshot?.identity.root ?? ""
        rootError = nil
        changingRoot = true
    }

    private func applyRoot(_ text: String) {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~"), context.device.isLocal { path = (path as NSString).expandingTildeInPath }
        guard path.hasPrefix("/") else {
            rootError = String(localized: "Enter an absolute path, such as /home/dev/app")
            return
        }
        rootError = nil
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        projects.setRoot(space: space, context: context, root: path)
    }

    // MARK: - Sections

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func hotReloadSection(_ snapshot: ProjectSnapshot) -> some View {
        ProjectHotReloadCard(
            snapshot: snapshot, isRemote: !context.device.isLocal,
            overrideURL: { $0.urls.first { $0.source == .override }?.url },
            onSetURL: { projects.setURLOverride(space: space, signature: $0, url: $1) },
            onToggleHidden: { toggleHidden($0, in: snapshot) })
    }

    private func toggleHidden(_ signature: String, in snapshot: ProjectSnapshot) {
        let server = (snapshot.devServers + snapshot.otherListeners).first { $0.signature == signature }
        projects.setHidden(space: space, signature: signature, hidden: !(server?.isHidden ?? false))
    }

    private func dockerSection(_ snapshot: ProjectSnapshot) -> some View {
        ProjectDockerCard(
            snapshot: snapshot, isRemote: !context.device.isLocal, isOtherExpanded: binding("otherCompose"),
            actions: ProjectDockerActions(
                attachCompose: { projects.attachCompose(space: space, name: $0) },
                detachCompose: { projects.detachCompose(space: space, name: $0) },
                attachContainer: { projects.attachContainer(space: space, name: $0) },
                dismissSuggestion: { projects.dismissSuggestion(space: space, name: $0) },
                detachContainer: { projects.detachContainer(space: space, name: $0) }))
    }

    private func hostsSection(_ snapshot: ProjectSnapshot) -> some View {
        ProjectHostsCard(
            snapshot: snapshot, linked: linkedHosts,
            onAttachVM: { projects.attachVM(space: space, vm: $0) },
            onDetachVM: { projects.detachVM(space: space, id: $0) },
            onUnlink: { projects.unlinkDevice(space: space, deviceID: $0) })
    }

    private func linksSection(_ snapshot: ProjectSnapshot) -> some View {
        ProjectLinksCard(urls: projectURLs(snapshot), isRemote: !context.device.isLocal)
    }

    private func filesSection(_ snapshot: ProjectSnapshot) -> some View {
        ProjectFilesCard(
            files: snapshot.files,
            envByFile: projectEnvKeys(snapshot))
    }

    private func otherListenersSection(_ snapshot: ProjectSnapshot) -> some View {
        ProjectOtherListenersCard(
            listeners: snapshot.otherListeners, isRemote: !context.device.isLocal,
            isExpanded: binding("other"), onToggleHidden: { toggleHidden($0, in: snapshot) })
    }

    private func hiddenSection(_ snapshot: ProjectSnapshot) -> some View {
        ProjectHiddenCard(
            devServers: snapshot.devServers, listeners: snapshot.otherListeners,
            isRemote: !context.device.isLocal, isExpanded: binding("hidden"),
            onSetURL: { projects.setURLOverride(space: space, signature: $0, url: $1) },
            onToggleHidden: { toggleHidden($0, in: snapshot) })
    }
}

/// Every URL of the project, first occurrence of each wins: dev servers (hidden ones too), then
/// compose containers, then attached containers.
func projectURLs(_ snapshot: ProjectSnapshot) -> [ProjectURL] {
    let all = snapshot.devServers.flatMap(\.urls)
        + (snapshot.compose.flatMap(\.containers) + snapshot.attachedContainers).flatMap(\.urls)
    var seen = Set<String>()
    return all.filter { seen.insert($0.url).inserted }
}

/// Env variable names by file, each name once in first-seen order. Values never leave the snapshot.
func projectEnvKeys(_ snapshot: ProjectSnapshot) -> [String: [String]] {
    Dictionary(grouping: snapshot.envEntries, by: \.file).mapValues { entries in
        var seen = Set<String>()
        return entries.map(\.key).filter { seen.insert($0).inserted }
    }
}
