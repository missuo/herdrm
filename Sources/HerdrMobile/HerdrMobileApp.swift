import SwiftUI

@main
struct HerdrMobileApp: App {
    @State private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The public half of the device key, for the pairing UI and support
        // tooling. Public by definition; the private key never leaves Keychain.
        UserDefaults.standard.set(
            DeviceKey.authorizedKeysLine(DeviceKey.ensure()),
            forKey: "deviceKey.publicLine"
        )
        // Nerd Font symbols for agent-TUI icon glyphs (Ghostty codepoint-maps
        // the PUA ranges to this family).
        MobileGhosttyRuntime.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-HerdrmChatDemo") {
                MobileChatDemoView()
            } else {
                root
                    // UI tests: `-HerdrmPairingURL herdrm://pair?…` takes the
                    // same path as the system opening the link, without its prompt.
                    .task {
                        if let link = UserDefaults.standard.string(forKey: "HerdrmPairingURL"),
                           let url = URL(string: link) {
                            model.openPairingURL(url)
                        }
                        // UI tests: `-HerdrmTestKeys <base64,…> -HerdrmTestDirect host:port:user`
                        // imports keys (no Face ID) and adds a direct server
                        // that picks among them automatically.
                        if let keys = UserDefaults.standard.string(forKey: "HerdrmTestKeys"),
                           let direct = UserDefaults.standard.string(forKey: "HerdrmTestDirect") {
                            for (i, encoded) in keys.split(separator: ",").enumerated() {
                                guard let data = Data(base64Encoded: String(encoded)) else { continue }
                                _ = try? SSHIdentityStore.shared.add(
                                    name: "Test key \(i + 1)", keyText: String(decoding: data, as: UTF8.self),
                                    passphrase: nil, requiresAuthentication: false)
                                try? await Task.sleep(nanoseconds: 10_000_000) // distinct addedAt
                            }
                            let parts = direct.split(separator: ":").map(String.init)
                            if parts.count == 3, let port = UInt16(parts[1]) {
                                model.addDevice(name: "Direct test", host: parts[0], port: port, username: parts[2],
                                                authMethod: .identity, password: "")
                            }
                        }
                    }
            }
            #else
            root
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS tears sockets down in the background; on return, re-prove the
            // connection instead of trusting a held one.
            if phase == .active, model.selectedDeviceID != nil {
                model.connectSelected()
            }
        }
    }

    private var root: some View {
        MobileRootView(model: model)
            // herdrm://pair?… from the system Camera scanning a Mac's code.
            .onOpenURL { model.openPairingURL($0) }
    }
}
