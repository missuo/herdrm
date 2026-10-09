import HerdrKit
import SwiftUI

/// Every Claude account grazr rotates through on one device, with what each
/// has left in its 5-hour, weekly and per-model windows.
struct GrazrAccountsSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var report: GrazrReport?
    @State private var failure: String?
    @State private var loading = false
    @State private var swapping = false
    /// grazr's word when Refresh could not ask Claude, shown by the button.
    @State private var refreshNote: String?
    @AppStorage("grazr.accounts.view") private var view = AccountsView.list
    @AppStorage("grazr.accounts.dialWindow") private var dialWindow = GrazrDialWindow.week

    enum AccountsView: String {
        case list, dial, clock
    }

    private var swapAction: PluginAction? {
        model.session(device.id).pluginActions
            .first { $0.pluginID == Grazr.pluginID }?
            .actions.first { $0.actionID == Grazr.swapActionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SheetHeader(
                    systemImage: "person.2",
                    title: String(localized: "Claude Accounts"),
                    subtitle: subtitle
                )
                Picker("View", selection: $view) {
                    Image(systemName: "list.bullet").tag(AccountsView.list)
                        .accessibilityLabel("List")
                    Image(systemName: "chart.pie").tag(AccountsView.dial)
                        .accessibilityLabel("Dial")
                    Image(systemName: "clock").tag(AccountsView.clock)
                        .accessibilityLabel("Clock")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the accounts as a list, grazr's rotation dial, or a clock of who runs when")
                .padding(.trailing, 16)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)

            content
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 520)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Button {
                    Task { await load(askClaude: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Ask Claude for every account's usage now, then reload")
                .disabled(loading)
                if loading || swapping {
                    ProgressView().controlSize(.small)
                } else if let refreshNote {
                    Text(refreshNote)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                        .help(refreshNote)
                }
                Spacer()
                if let swapAction {
                    Button("Swap to Next Account") {
                        swapping = true
                        model.runPluginAction(swapAction, on: device, target: nil) {
                            swapping = false
                            Task { await load() }
                        }
                    }
                    .disabled(swapping)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .task { await load() }
    }

    private var subtitle: String {
        guard let report else { return device.name }
        var parts = [
            device.name,
            String(localized: "swaps below \(report.sessionThreshold)% 5h · \(report.weeklyThreshold)% week"),
        ]
        if !report.enabled { parts.append(String(localized: "automatic swaps off")) }
        if report.dryRun { parts.append(String(localized: "dry run")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            message(failure, systemImage: "exclamationmark.triangle")
        } else if let report {
            if !report.installed {
                message(String(localized: "grazr is not installed on \(device.name)."), systemImage: "person.crop.circle.badge.questionmark")
            } else if report.accounts.isEmpty {
                message(String(localized: "No accounts enrolled yet."), systemImage: "person.crop.circle.badge.plus")
            } else if view == .dial || view == .clock {
                ScrollView {
                    VStack(spacing: 6) {
                        HStack {
                            Spacer()
                            Picker("Window", selection: $dialWindow) {
                                Text("Week").tag(GrazrDialWindow.week)
                                Text(view == .clock ? "24h" : "5h").tag(GrazrDialWindow.session)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help(view == .clock ? "How far ahead the clock looks" : "Which window fills the slices")
                        }
                        // Redraws each minute so a window past its reset shows as refilled.
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            if view == .clock {
                                GrazrAccountsClock(report: report, span: dialWindow, now: context.date, agentNames: agentNames)
                            } else {
                                GrazrAccountsDial(report: report, window: dialWindow, now: context.date, agentNames: agentNames)
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(report.sortedAccounts) { account in
                            GrazrAccountCard(
                                report: report,
                                account: account,
                                now: Date(),
                                switching: swapping,
                                agentNames: agentNames,
                                onSwitch: { switchTo(account) },
                                onReauthenticate: { model.reauthenticateGrazrAccount(account, on: device) },
                                onSetUpToken: { model.setUpGrazrToken(account, on: device) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Agents on this device by pane id, for what says who is pinned where.
    private var agentNames: [String: String] {
        Dictionary(
            model.session(device.id).agents.map { ($0.paneID, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func switchTo(_ account: GrazrAccount) {
        swapping = true
        model.switchGrazrAccount(account, on: device) {
            swapping = false
            Task { await load() }
        }
    }

    /// Reads grazr's records. With `askClaude`, has grazr refresh them from
    /// Claude first: its records of parked accounts otherwise stay as they
    /// were when grazr left them, so a plain reload shows nothing new.
    private func load(askClaude: Bool = false) async {
        loading = true
        defer { loading = false }
        if askClaude {
            let output = try? await DeviceFileService(device: device).run(Grazr.refreshCommand)
            let result = output.flatMap { try? JSONDecoder().decode(GrazrSwitchResult.self, from: $0) }
            refreshNote = result?.ok == false ? result?.summary : nil
        }
        do {
            let output = try await DeviceFileService(device: device).run(Grazr.readerCommand)
            report = try JSONDecoder().decode(GrazrReport.self, from: output)
            failure = nil
        } catch {
            failure = String(localized: "Could not read grazr's accounts on \(device.name): \(error.localizedDescription)")
        }
    }
}

private struct GrazrAccountCard: View {
    let report: GrazrReport
    let account: GrazrAccount
    let now: Date
    let switching: Bool
    let agentNames: [String: String]
    let onSwitch: () -> Void
    let onReauthenticate: () -> Void
    let onSetUpToken: () -> Void

    private var isActive: Bool { account.id == report.active }

    /// Agents pinned to this account, by name.
    private var pinnedAgents: [String] {
        report.pinnedPanes(for: account).map { agentNames[$0] ?? $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.statsAccount : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = account.plan { badge(plan.label, color: Theme.textSecondary) }
                if isActive { badge(String(localized: "Active"), color: Theme.success) }
                if let block = report.block(for: account, now: now) {
                    badge(String(localized: "Blocked: \(block.reason)"), color: Theme.danger)
                }
                if !report.isListed(account) {
                    badge(String(localized: "Not in ACCOUNTS"), color: Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if report.canSwitch(to: account, now: now) {
                    Button("Switch", action: onSwitch)
                        .controlSize(.small)
                        .disabled(switching)
                } else if report.needsSignIn(account, now: now) {
                    Button("Re-authenticate…", action: onReauthenticate)
                        .controlSize(.small)
                        .help("Sign in to this account again in a terminal on the device")
                }
            }
            if let organization = account.organization, organization != "\(account.name)'s Organization" {
                Text(organization)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            VStack(spacing: 5) {
                ForEach(Array(account.sortedWindows.enumerated()), id: \.offset) { _, window in
                    windowRow(window)
                }
            }

            if let updated = account.updated {
                Text("Reading from \(Self.relative(Date(timeIntervalSince1970: updated), now: now))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
            if !pinnedAgents.isEmpty {
                pinnedLine
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Theme.itemWashSelected : Theme.itemWash)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Theme.statsAccount.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    /// The agents that have this account to themselves, and, once the
    /// sign-in they run on is close to lapsing, a way to renew it.
    private var pinnedLine: some View {
        let days = account.tokenDaysLeft(now: now)
        return HStack(spacing: 8) {
            Label {
                Text("Pinned: \(pinnedAgents.joined(separator: ", "))")
            } icon: {
                Image(systemName: "pin.fill")
            }
            .foregroundStyle(Theme.statsAccount)
            .lineLimit(1)
            if days ?? 0 < 30 {
                Text(days.map { String(localized: "sign-in expires in \($0) days") } ?? String(localized: "sign-in expired"))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Renew…", action: onSetUpToken)
                    .controlSize(.small)
                    .help("Sign in to this account again in a terminal on the device, for the agents pinned to it")
            }
        }
        .font(.system(size: 11))
    }

    private func windowRow(_ window: GrazrWindow) -> some View {
        let left = window.left(now: now)
        let color = GrazrStyle.tint(left: left, threshold: report.threshold(for: window))
        return HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            ProgressView(value: Double(left), total: 100)
                .progressViewStyle(.linear)
                .tint(color)
            Text("\(left)% left")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 62, alignment: .trailing)
            Text(resetText(window))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(1)
        }
    }

    private func resetText(_ window: GrazrWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "" }
        guard window.isOpen(now: now) else { return String(localized: "reset since") }
        return String(localized: "resets \(GrazrStyle.time(resetsAt, now: now))")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
