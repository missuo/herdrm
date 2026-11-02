import HerdrKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Keys: the SSH private keys this phone signs in with when it reaches a
/// server directly (an IP or hostname, no relay).
struct IdentitiesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var identities = SSHIdentityStore.shared.identities
    @State private var adding = false
    @State private var pendingDelete: SSHIdentity?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if identities.isEmpty {
                        Text(String(localized: "No keys yet. Add the private key you use for your servers; Herdrm tries the right one when it connects."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(identities) { identity in
                        IdentityRow(identity: identity)
                            .swipeActions {
                                Button(String(localized: "Delete"), role: .destructive) { pendingDelete = identity }
                            }
                            .contextMenu {
                                Button(String(localized: "Delete"), role: .destructive) { pendingDelete = identity }
                            }
                    }
                } footer: {
                    Text(String(localized: "Keys stay in this iPhone's Keychain: never synced to iCloud, backed up to another device or shown again after import. Only the fingerprint is displayed."))
                }
            }
            .navigationTitle(String(localized: "Keys"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(String(localized: "Add Key"))
                }
            }
            .sheet(isPresented: $adding, onDismiss: reload) {
                AddIdentitySheet { _ in }
            }
            .confirmationDialog(
                String(localized: "Delete this key?"),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let pendingDelete { SSHIdentityStore.shared.remove(pendingDelete.id) }
                    pendingDelete = nil
                    reload()
                }
            } message: {
                Text(String(localized: "It is erased from this iPhone. Servers that use it need another key to sign in."))
            }
        }
    }

    private func reload() { identities = SSHIdentityStore.shared.identities }
}

struct IdentityRow: View {
    let identity: SSHIdentity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name)
                Text([identity.kind.label, identity.fingerprint].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if identity.requiresAuthentication {
                Image(systemName: "faceid")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Needs Face ID"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Import one private key: paste it, or pick the file. The text is checked
/// before anything is stored, and the clipboard is cleared once a key has
/// been pasted from it.
struct AddIdentitySheet: View {
    let onAdded: (SSHIdentity) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keyText = ""
    @State private var passphrase = ""
    @State private var requiresAuthentication = true
    @State private var importing = false
    @State private var error: String?

    private var summary: SSHPrivateKeyFile.Summary? { try? SSHPrivateKeyFile.summarize(keyText) }

    /// Why the pasted text isn't usable, once there is some.
    private var problem: String? {
        guard !keyText.isEmpty else { return nil }
        do {
            _ = try SSHPrivateKeyFile.summarize(keyText)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name"), text: $name, prompt: Text(String(localized: "e.g. Work servers")))
                }
                Section {
                    TextEditor(text: $keyText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel(String(localized: "Private key"))
                    HStack {
                        Button(String(localized: "Paste")) { pasteKey() }
                        Spacer()
                        Button(String(localized: "Import File…")) { importing = true }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text(String(localized: "Private Key"))
                } footer: {
                    if let summary {
                        Text([summary.kind.label, summary.fingerprint, summary.encrypted ? String(localized: "passphrase protected") : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11, design: .monospaced))
                    } else if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text(String(localized: "OpenSSH or PEM, Ed25519, ECDSA or RSA, e.g. the contents of ~/.ssh/id_ed25519."))
                    }
                }
                if summary?.encrypted == true {
                    Section(String(localized: "Passphrase")) {
                        SecureField(String(localized: "Passphrase"), text: $passphrase)
                            .textContentType(.password)
                    }
                }
                Section {
                    Toggle(String(localized: "Require Face ID to Use"), isOn: $requiresAuthentication)
                } footer: {
                    Text(String(localized: "The Keychain releases the key only after Face ID or the passcode. One unlock covers the next two minutes."))
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(String(localized: "Add Key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(summary == nil || (summary?.encrypted == true && passphrase.isEmpty))
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text, .item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
                      let text = String(data: data, encoding: .utf8)
                else {
                    error = String(localized: "Couldn't read that file.")
                    return
                }
                keyText = text
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            }
        }
        .interactiveDismissDisabled(!keyText.isEmpty)
    }

    private func pasteKey() {
        guard let text = UIPasteboard.general.string else { return }
        keyText = text
        // A private key shouldn't linger on the clipboard (or Universal
        // Clipboard) once it is in the form.
        if (try? SSHPrivateKeyFile.summarize(text)) != nil { UIPasteboard.general.string = "" }
    }

    private func save() {
        do {
            let identity = try SSHIdentityStore.shared.add(
                name: name, keyText: keyText,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                requiresAuthentication: requiresAuthentication)
            keyText = ""
            passphrase = ""
            onAdded(identity)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Add Device's choice of key: Automatic, one of the stored keys, or a new one
/// added on the spot.
struct IdentityPicker: View {
    @Binding var identityID: UUID?
    @State private var identities = SSHIdentityStore.shared.identities
    @State private var adding = false

    var body: some View {
        Picker(String(localized: "Key"), selection: $identityID) {
            Text(String(localized: "Automatic")).tag(UUID?.none)
            ForEach(identities) { identity in
                Text(identity.name).tag(UUID?.some(identity.id))
            }
        }
        Button(String(localized: "Add Key…")) { adding = true }
            .sheet(isPresented: $adding) {
                AddIdentitySheet { identity in
                    identities = SSHIdentityStore.shared.identities
                    identityID = identity.id
                }
            }
    }
}
