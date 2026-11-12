import AppKit
import HerdrKit
import SwiftUI

@MainActor
final class DeviceFileBrowserModel: ObservableObject {
    @Published private(set) var device: Device = .local
    @Published private(set) var currentPath = "~"
    @Published var pathText = "~"
    @Published private(set) var entries: [DeviceFileEntry] = []
    @Published private(set) var sort = DeviceFileSort()
    @Published var selectedPaths: Set<String> = []
    @Published var includesHidden = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var service = DeviceFileService(device: .local)
    private var generation = 0
    private let listDirectory: @MainActor (DeviceFileService, String, Bool) async throws -> DeviceDirectoryListing

    init(
        listDirectory: @escaping @MainActor (DeviceFileService, String, Bool) async throws -> DeviceDirectoryListing = {
            try await $0.listDirectory(at: $1, includingHidden: $2)
        }
    ) {
        self.listDirectory = listDirectory
    }

    var selectedEntries: [DeviceFileEntry] {
        entries.filter { $0.kind == .regularFile && selectedPaths.contains($0.path) }
    }

    func configure(for device: Device) async {
        guard self.device.id != device.id || entries.isEmpty else { return }
        generation += 1
        self.device = device
        service = DeviceFileService(device: device)
        currentPath = "~"
        pathText = "~"
        entries = []
        selectedPaths = []
        error = nil
        await refresh()
    }

    func refresh() async {
        // Automatic refreshes after transfers must not submit a path draft.
        let displayedPath = (currentPath as NSString).abbreviatingWithTildeInPath
        await load(currentPath, updatePathText: pathText == displayedPath)
    }

    func navigate(to path: String) async {
        await load(path)
    }

    func open(_ entry: DeviceFileEntry) async {
        if entry.kind == .directory {
            await load(entry.path)
        } else {
            selectedPaths = [entry.path]
        }
    }

    func goUp() async {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    func goHome() async {
        await load("~")
    }

    func toggleHidden() async {
        includesHidden.toggle()
        await refresh()
    }

    func sortBy(_ column: DeviceFileSort.Column) {
        sort.select(column)
        entries = sort.sorted(entries)
    }

    private func load(_ requestedPath: String, updatePathText: Bool = true) async {
        generation += 1
        let requestGeneration = generation
        let pathTextAtRequest = pathText
        isLoading = true
        error = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        do {
            let listing = try await listDirectory(service, requestedPath, includesHidden)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            if currentPath != listing.path { selectedPaths = [] }
            currentPath = listing.path
            // A slow directory reply must not replace a path being edited.
            if updatePathText && pathText == pathTextAtRequest {
                pathText = (listing.path as NSString).abbreviatingWithTildeInPath
            }
            entries = sort.sorted(listing.entries)
            selectedPaths.formIntersection(entries.filter { $0.kind == .regularFile }.map(\.path))
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }
}

struct DeviceFilesView: View {
    @ObservedObject var model: AppModel
    @StateObject private var local = DeviceFileBrowserModel()
    @StateObject private var target = DeviceFileBrowserModel()
    @StateObject private var transfer = DeviceFileTransferModel()
    @State private var targetDeviceID = Device.local.id

    private var targetDevice: Device {
        model.device(targetDeviceID) ?? .local
    }

    var body: some View {
        VStack(spacing: 0) {
            deviceBar
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                DeviceFilePane(title: String(localized: "Local"), device: .local, browser: local)
                transferButtons
                DeviceFilePane(title: targetDevice.name, device: targetDevice, browser: target)
            }
            if transfer.isTransferring || !transfer.label.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                transferBar
            }
        }
        .background(Theme.contentBackground)
        .task {
            targetDeviceID = preferredTargetDeviceID()
        }
        // The running batch task retains the model, so its deinit can't cancel;
        // stop here, as leaving Files did before multi-file transfers.
        .onDisappear { transfer.cancel() }
        .onChange(of: model.deviceFilter) { _, deviceID in
            if let deviceID, transferDevices.contains(where: { $0.id == deviceID }) {
                targetDeviceID = deviceID
            }
        }
        .onChange(of: transferDevices.map(\.id)) { _, ids in
            if !ids.contains(targetDeviceID) {
                targetDeviceID = preferredTargetDeviceID()
            }
        }
        .confirmationDialog(
            "Files Already Exist",
            isPresented: Binding(
                get: { transfer.pendingBatch != nil },
                // SwiftUI may clear the binding before running the chosen button's
                // action. Defer the dismiss-means-cancel check so a choice made in
                // the dialog has already taken the pending batch by then.
                set: { if !$0 { Task { @MainActor in if transfer.pendingBatch != nil { transfer.cancel() } } } }
            ),
            presenting: transfer.pendingBatch
        ) { batch in
            Button("Replace Existing", role: .destructive) { transfer.startPending(batch, resolution: .replace) }
            Button("Keep Both") { transfer.startPending(batch, resolution: .keepBoth) }
            Button("Skip Existing") { transfer.startPending(batch, resolution: .skip) }
            Button("Cancel", role: .cancel) { transfer.cancel() }
        } message: { batch in
            Text("\(batch.conflictingNames.count) selected files already exist in the destination. Apply this choice to every conflicting file in this batch.")
        }
        .alert(
            "Transfer Failed",
            isPresented: Binding(
                get: { transfer.error != nil },
                set: { if !$0 { transfer.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transfer.error ?? "")
        }
    }

    private var deviceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(Theme.textTertiary)
            Text("Local")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("Transfer with")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Picker("", selection: $targetDeviceID) {
                ForEach(transferDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(transfer.isTransferring)
            Spacer()
            Image(systemName: targetDevice.isLocal ? "laptopcomputer" : "network")
                .foregroundStyle(Theme.deviceTint(targetDevice))
            Text(targetDevice.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private var transferButtons: some View {
        VStack(spacing: 10) {
            Spacer()
            Button {
                prepare(.upload)
            } label: {
                Image(systemName: "arrow.right")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Copy selected local files to \(targetDevice.name)")
            .accessibilityLabel("Upload selected files")
            .disabled(!canUpload)

            Button {
                prepare(.download)
            } label: {
                Image(systemName: "arrow.left")
                    .frame(width: 28, height: 24)
            }
            .buttonStyle(.bordered)
            .help("Copy selected files from \(targetDevice.name) to Local")
            .accessibilityLabel("Download selected files")
            .disabled(!canDownload)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 58)
        .background(Theme.statusBarBackground.opacity(0.55))
        .overlay(
            HStack {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                Spacer()
                Rectangle().fill(Theme.hairline).frame(width: 1)
            }
        )
    }

    private var transferBar: some View {
        HStack(spacing: 10) {
            if transfer.isTransferring {
                ProgressView(value: transfer.progress?.fractionCompleted ?? 0)
                    .frame(maxWidth: 180)
                    .accessibilityLabel("Batch transfer progress")
            }
            Text(transfer.label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            if let progress = transfer.progress?.currentFile {
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: progress.completedBytes,
                        countStyle: .file
                    )
                )
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
            }
            if transfer.isTransferring {
                Button("Cancel") { transfer.cancel() }
                    .controlSize(.small)
            } else {
                Button { transfer.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss transfer result")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.statusBarBackground)
    }

    private var canUpload: Bool {
        !transfer.isTransferring && !local.isLoading && !target.isLoading && !local.selectedEntries.isEmpty
    }

    private var canDownload: Bool {
        !transfer.isTransferring && !local.isLoading && !target.isLoading && !target.selectedEntries.isEmpty
    }

    /// Devices that can browse and transfer files. A tailcat tunnel carries
    /// only the herdr socket — no file system access — so it's left out.
    private var transferDevices: [Device] {
        model.devices.filter { !$0.isTailcat }
    }

    private func preferredTargetDeviceID() -> UUID {
        let devices = transferDevices
        if let filtered = model.deviceFilter, devices.contains(where: { $0.id == filtered }) { return filtered }
        return devices.first(where: { !$0.isLocal })?.id
            ?? devices.first?.id
            ?? Device.local.id
    }

    private func prepare(_ direction: DeviceFileTransferBatch.Direction) {
        transfer.prepare(
            direction: direction,
            entries: direction == .upload ? local.selectedEntries : target.selectedEntries,
            targetDevice: targetDevice,
            localDirectory: local.currentPath,
            targetDirectory: target.currentPath
        ) {
            switch direction {
            case .upload: await target.refresh()
            case .download: await local.refresh()
            }
        }
    }
}

struct DeviceFilePane: View {
    let title: String
    let device: Device
    @ObservedObject var browser: DeviceFileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Rectangle().fill(Theme.hairline).frame(height: 1)
            pathBar
            columnHeader
            Rectangle().fill(Theme.hairline).frame(height: 1)
            listing
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
        .task(id: device.id) {
            await browser.configure(for: device)
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: device.isLocal ? "laptopcomputer" : "network")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.deviceTint(device))
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            if browser.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await browser.toggleHidden() }
            } label: {
                Image(systemName: browser.includesHidden ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help(browser.includesHidden ? "Hide hidden files" : "Show hidden files")
            Button {
                Task { await browser.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await browser.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(browser.currentPath == "/")
            .help("Parent folder")

            Button {
                Task { await browser.goHome() }
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.plain)
            .help("Home folder")

            TextField("Path", text: $browser.pathText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .onSubmit {
                    Task { await browser.navigate(to: browser.pathText) }
                }

            if device.isLocal {
                Button {
                    chooseLocalFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Choose folder")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            sortButton("Name", column: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton("Size", column: .size, alignment: .trailing)
                .frame(width: 72, alignment: .trailing)
            sortButton("Modified", column: .modified, alignment: .leading)
                .frame(width: 126, alignment: .leading)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 12)
        .frame(height: 25)
        .background(Theme.statusBarBackground.opacity(0.7))
    }

    private func sortButton(
        _ title: LocalizedStringKey,
        column: DeviceFileSort.Column,
        alignment: Alignment
    ) -> some View {
        let selected = browser.sort.column == column
        let direction: LocalizedStringKey = browser.sort.ascending ? "Ascending" : "Descending"
        return Button {
            browser.sortBy(column)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if selected {
                    Image(systemName: browser.sort.ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 25, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.text : Theme.textTertiary)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selected ? direction : "Not sorted"))
        .help("Click to change sort order")
    }

    private var listing: some View {
        List(selection: $browser.selectedPaths) {
            ForEach(browser.entries) { entry in
                Group {
                    if entry.kind == .directory {
                        Button { Task { await browser.open(entry) } } label: { fileRow(entry) }
                            .buttonStyle(.plain)
                    } else {
                        fileRow(entry)
                    }
                }
                .tag(entry.path)
                .selectionDisabled(entry.kind != .regularFile)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 28)
        .accessibilityLabel("Files in \(title)")
        .overlay {
            if browser.entries.isEmpty, !browser.isLoading, browser.error == nil {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("This folder contains no visible items.")
                )
            }
        }
    }

    private func fileRow(_ entry: DeviceFileEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: entry))
                .font(.system(size: 11.5))
                .foregroundStyle(entry.kind == .directory ? Theme.accent : Theme.textTertiary)
                .frame(width: 16)
            Text(entry.name)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(size(for: entry))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 72, alignment: .trailing)
            Text(modified(for: entry))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 126, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = browser.error {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                Text(error)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text("\(browser.entries.count) items")
            }
            Spacer()
            if !browser.selectedEntries.isEmpty {
                Text("Selected: \(browser.selectedEntries.count)")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.statusBarBackground.opacity(0.7))
    }

    private func icon(for entry: DeviceFileEntry) -> String {
        switch entry.kind {
        case .directory: return entry.isPackage ? "shippingbox" : "folder"
        case .regularFile: return "doc"
        case .symbolicLink: return "link"
        case .other: return "questionmark.square"
        }
    }

    private func size(for entry: DeviceFileEntry) -> String {
        guard let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func modified(for entry: DeviceFileEntry) -> String {
        guard let date = entry.modificationDate else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: browser.currentPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await browser.navigate(to: url.path) }
        }
    }
}
