import HerdrKit
import SwiftUI

/// The Accounts window's sync switch and what the sync is doing: the
/// first-enable preview with Apply, or one line per device afterwards.
struct GrazrSyncSection: View {
    @ObservedObject var model: AppModel
    let device: Device
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $syncing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep accounts in sync across devices")
                    Text("Order and active account follow the device that changed last. Pins and thresholds stay per device.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("grazr.sync.toggle")
            .onChange(of: syncing) { _, on in
                if on != model.grazrSync.enabled { model.grazrSync.setEnabled(on) }
            }
            status
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear { syncing = model.grazrSync.enabled }
    }

    @ViewBuilder
    private var status: some View {
        switch model.grazrSyncStatus {
        case .off:
            EmptyView()
        case .fewDevices(let name):
            if let name {
                Text("Only \(name) runs grazr, nothing to sync yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        case .preview(let lines, _):
            ForEach(lines) { lineView($0) }
            HStack {
                Spacer()
                Button("Apply") { model.grazrSync.apply() }
                    .controlSize(.small)
                    .accessibilityIdentifier("grazr.sync.apply")
            }
        case .lines(let lines):
            ForEach(lines) { lineView($0) }
        }
    }

    private func lineView(_ line: GrazrSyncLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.text)
                .font(.system(size: 11))
                .foregroundStyle(line.tone == .warning ? Theme.warning : Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let account = line.blockedAccount, let target = line.device {
                Button("Re-authenticate…") { model.reauthenticateGrazrAccount(account, on: target) }
                    .controlSize(.small)
                    .help("Sign in to this account again in a terminal on the device")
            }
        }
        .accessibilityIdentifier("grazr.sync.line.\(line.id)")
    }
}
