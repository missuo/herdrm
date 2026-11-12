import AppKit
import HerdrKit
import SwiftUI

// Row views of the Project pane. They are plain value views: every action is a closure the
// pane wires to `ProjectInspectorModel`, so the rows stay small.

/// Small rounded tag next to a row title ("loopback only", "matched by name", ...).
struct ProjectTag: View {
    let text: LocalizedStringKey
    var tint: Color = Theme.textSecondary
    var systemImage: String?

    init(_ text: LocalizedStringKey, tint: Color = Theme.textSecondary, systemImage: String? = nil) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8.5)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
        .lineLimit(1)
        .fixedSize()
    }
}

/// A tag that shows a verbatim string (a unit or log file name), not a catalog key.
struct ProjectVerbatimTag: View {
    let text: String
    let systemImage: String
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8.5))
            Text(verbatim: text).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 4))
        .lineLimit(1)
        .help(help ?? text)
    }
}

struct ProjectIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textSecondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

// MARK: - URLs

enum ProjectURLActions {
    static func open(_ url: ProjectURL) {
        guard let target = URL(string: url.url) else { return }
        NSWorkspace.shared.open(target)
    }

    static func copy(_ url: ProjectURL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.url, forType: .string)
    }
}

/// The URL chips of one service: a globe, the link (or plain text when only the host can reach
/// it) and, when `showsCopy`, a copy icon.
struct ProjectURLButtons: View {
    let urls: [ProjectURL]
    /// The device is not this Mac: a loopback-only URL would open the Mac's own localhost.
    var isRemote = false
    var showsCopy = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                Image(systemName: "globe")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
                if isRemote && url.loopbackOnHost {
                    Text(verbatim: url.label)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Only reachable from the host itself")
                } else {
                    Button { ProjectURLActions.open(url) } label: {
                        Text(verbatim: url.label)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Open this URL")
                }
                if showsCopy {
                    ProjectIconButton(systemImage: "doc.on.doc", label: "Copy URL") { ProjectURLActions.copy(url) }
                }
            }
        }
    }
}

/// Text field for a URL override. Saving an empty field clears the override.
struct URLOverridePopover: View {
    @State private var text: String
    let onSave: (String?) -> Void
    let onCancel: () -> Void

    init(initial: String, onSave: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetSectionLabel("URL override")
            TextField(text: $text, prompt: Text(verbatim: "https://app.example.test")) { Text("URL override") }
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(save)
            Text("Leave empty to go back to the detected URL.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
    }
}

/// "Project · name" for the titlebar; observes the inspector so it follows snapshot changes.
struct ProjectTitleText: View {
    @ObservedObject var projects: ProjectInspectorModel
    let space: SpaceRef?

    var body: some View {
        if let name = space.flatMap({ projects.identity(for: $0)?.name }) {
            Text("Project · \(name)")
        } else {
            Text("Project")
        }
    }
}
