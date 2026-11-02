import AppKit
import CoreImage.CIFilterBuiltins
import HerdrKit
import SwiftUI

/// Keeps this Mac reachable for Herdrm on iPhone through the relay, and owns
/// pairing. On while "Allow iPhone access" is on; the host keys and paired
/// phones persist (Keychain, Application Support).
@MainActor
final class RelayHostController: ObservableObject {
    static let shared = RelayHostController()

    static let enabledKey = "relay.enabled"
    static let urlKey = "relay.url"

    @Published private(set) var status: RelayHost.Status = .stopped
    @Published private(set) var pairing: RelayHost.PendingPairing?
    @Published private(set) var phones: [RelayPairedPhone] = []
    /// The phone that paired while the code was showing, for the sheet's
    /// confirmation.
    @Published var justPaired: RelayPairedPhone?
    @Published private(set) var remoteLoginOn = true

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            restart()
        }
    }

    @Published var relayURL: String {
        didSet { UserDefaults.standard.set(relayURL, forKey: Self.urlKey) }
    }

    private let store = RelayKeychainHostStore()
    private var host: RelayHost?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        relayURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? RelayProtocol.defaultRelayURL.absoluteString
        phones = store.phones()
    }

    var hostID: String { RelayProtocol.hostID(for: store.signingKey.publicKey) }

    func startIfEnabled() {
        if enabled, host == nil { restart() }
    }

    /// Applies the relay URL and the switch: tears the host down and, when
    /// on, starts a fresh one.
    func restart() {
        let old = host
        host = nil
        pairing = nil
        Task { await old?.stop() }
        refreshRemoteLogin()
        guard enabled else {
            status = .stopped
            return
        }
        let url = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { ["wss", "ws"].contains($0.scheme ?? "") ? $0 : nil } ?? RelayProtocol.defaultRelayURL
        let host = RelayHost(relay: url, store: store) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.host = host
        Task { await host.start() }
    }

    private func handle(_ event: RelayHost.Event) {
        switch event {
        case .status(let s): status = s
        case .pairingChanged(let p): pairing = p
        case .paired(let phone):
            phones = store.phones()
            justPaired = phone
        }
    }

    func beginPairing() {
        justPaired = nil
        refreshRemoteLogin()
        guard let host else { return }
        Task { pairing = await host.beginPairing() }
    }

    func cancelPairing() {
        guard let host else { return }
        Task { await host.cancelPairing() }
    }

    func remove(_ phone: RelayPairedPhone) {
        if let host {
            Task {
                await host.removePhone(phone.id)
                phones = store.phones()
            }
        } else {
            store.remove(phoneID: phone.id)
            RelayAuthorizedKeys.remove(phoneID: phone.id)
            phones = store.phones()
        }
    }

    func refreshRemoteLogin() {
        Task.detached {
            let on = RelayHost.remoteLoginEnabled()
            await MainActor.run { self.remoteLoginOn = on }
        }
    }
}

struct RelaySettingsView: View {
    @ObservedObject var controller = RelayHostController.shared
    @State private var showPairing = false
    @State private var editingURL = ""

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $controller.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow Herdrm on iPhone")
                        Text("Your iPhone reaches this Mac from any network, even without a public IP. The connection goes through Herdrm's relay and is end-to-end encrypted: the relay can't read it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if controller.enabled {
                    statusRow
                }
            }

            if controller.enabled, !controller.remoteLoginOn {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Remote Login is off", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Herdrm on iPhone signs in to this Mac over SSH. Turn on Remote Login in System Settings → General → Sharing.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Open Sharing Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button("Check Again") { controller.refreshRemoteLogin() }
                        }
                    }
                }
            }

            if controller.enabled {
                Section {
                    Button {
                        controller.beginPairing()
                        showPairing = true
                    } label: {
                        Label("Pair iPhone…", systemImage: "qrcode")
                    }
                    .disabled(controller.status != .online)
                } footer: {
                    Text("Shows a code to scan with Herdrm on iPhone. It works once and expires after 10 minutes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Paired iPhones") {
                if controller.phones.isEmpty {
                    Text("No iPhones yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.phones) { phone in
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(phone.name)
                                Text("Paired \(phone.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { controller.remove(phone) }
                                .accessibilityLabel(Text("Remove \(phone.name)"))
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Advanced") {
                    HStack {
                        TextField("Relay", text: $editingURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .onSubmit(applyURL)
                        Button("Apply", action: applyURL)
                            .disabled(editingURL == controller.relayURL)
                    }
                    LabeledContent("Mac ID") {
                        Text(controller.hostID)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
        .onAppear {
            editingURL = controller.relayURL
            controller.refreshRemoteLogin()
        }
        .sheet(isPresented: $showPairing, onDismiss: { controller.cancelPairing() }) {
            RelayPairingSheet(controller: controller)
        }
    }

    private func applyURL() {
        controller.relayURL = editingURL
        controller.restart()
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch controller.status {
        case .online: return String(localized: "Connected to the relay")
        case .connecting: return String(localized: "Connecting to the relay…")
        case .stopped: return String(localized: "Off")
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .online: return .green
        case .connecting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }
}

/// The QR code a phone scans to pair, until it does or the code expires.
struct RelayPairingSheet: View {
    @ObservedObject var controller: RelayHostController
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            if let phone = controller.justPaired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Paired with \(phone.name)")
                    .font(.title3.weight(.semibold))
                Text("Your iPhone can now reach this Mac from anywhere.")
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else if let pairing = controller.pairing {
                Text("Scan with Herdrm on iPhone")
                    .font(.title3.weight(.semibold))
                Text("In Herdrm on your iPhone, tap Add Device → Pair with Mac → Scan. The iPhone Camera app works too.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let image = Self.qrImage(pairing.link.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 230, height: 230)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(Text("Pairing code for \(pairing.link.hostName)"))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(pairing.expires.timeIntervalSince(context.date)))
                    Text(left > 0
                         ? String(localized: "Expires in \(left / 60):\(String(format: "%02d", left % 60))")
                         : String(localized: "This code has expired."))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(copied ? "Copied" : "Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.link.url.absoluteString, forType: .string)
                        copied = true
                    }
                    Button("New Code") {
                        copied = false
                        controller.beginPairing()
                    }
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Text("Anyone with this code can pair once, so only show it to your own phone.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
