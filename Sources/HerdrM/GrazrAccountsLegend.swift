import HerdrKit
import SwiftUI

/// The rows under the dial and the clock: number, dot, name, what is left in
/// the shown window (and each model's week), and where the account stands.
struct GrazrAccountsLegend: View {
    let report: GrazrReport
    let window: GrazrDialWindow
    let now: Date
    /// Agent names by pane id, for an account an agent is pinned to.
    var agentNames: [String: String] = [:]
    /// The clock's account colours; nil fills only the active account's dot.
    var dot: ((GrazrAccount) -> Color?)? = nil

    private var rotation: [GrazrAccount] { report.dialOrder(now: now) }
    private var next: GrazrAccount? { report.predictedNext(now: now) }
    private var models: [String] { window == .week ? report.modelScopes : [] }
    private let modelColumnWidth: CGFloat = 44
    /// Narrower beside model columns, so the account names keep their room.
    private var statusWidth: CGFloat { models.isEmpty ? 170 : 150 }

    var body: some View {
        let unlisted = report.sortedAccounts.filter { account in !rotation.contains { $0.id == account.id } }
        VStack(spacing: 0) {
            if !models.isEmpty {
                // Names the columns once rather than repeating the model on every row.
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Text("All")
                        .frame(width: 40, alignment: .trailing)
                    ForEach(models, id: \.self) { scope in
                        Text(scope)
                            .lineLimit(1)
                            .frame(width: modelColumnWidth, alignment: .trailing)
                    }
                    Color.clear.frame(width: statusWidth, height: 1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(rotation.enumerated()), id: \.element.id) { index, account in
                row(number: index + 1, account: account)
            }
            ForEach(unlisted) { account in
                row(number: nil, account: account)
            }
        }
        .padding(.horizontal, 4)
    }

    private func row(number: Int?, account: GrazrAccount) -> some View {
        let isActive = account.id == report.active
        let left = account.window(window)?.left(now: now)
        let (status, color) = status(of: account)
        let fill = dot.flatMap { $0(account) } ?? (isActive ? Theme.statsAccount : .clear)
        return HStack(spacing: 8) {
            Text(number.map { "\($0)" } ?? "–")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14, alignment: .trailing)
            Circle()
                .fill(fill)
                .overlay(Circle().stroke(fill == .clear ? Theme.textGhost : .clear, lineWidth: 1.2))
                .frame(width: 8, height: 8)
            Text(account.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.statsAccount : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            // Pinned yet still shared (PINNED_ROTATION=keep, or the active
            // account): the status says where it stands in the rotation, so
            // the agents it is pinned to go beside the name.
            let saysPinned = !isActive && report.heldAccountIDs.contains(account.id)
            let agents = saysPinned ? [] : pinnedAgents(of: account)
            if !agents.isEmpty {
                Label {
                    Text(agents.joined(separator: ", "))
                } icon: {
                    Image(systemName: "pin.fill")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.statsAccount)
                .lineLimit(1)
                .layoutPriority(-1)
                .help(report.keepsPinnedInRotation
                    ? String(localized: "Pinned: \(agents.joined(separator: ", ")); also in grazr's shared rotation")
                    : String(localized: "Pinned: \(agents.joined(separator: ", ")); leaves the shared rotation once grazr swaps away"))
            }
            Spacer(minLength: 8)
            Text(left.map { "\($0)%" } ?? "–")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(left.map { GrazrStyle.tint(left: $0, threshold: account.window(window).flatMap(report.threshold(for:))) } ?? Theme.textTertiary)
                .frame(width: 40, alignment: .trailing)
            ForEach(models, id: \.self) { scope in
                let model = account.modelWindow(scope)
                let modelLeft = model?.left(now: now)
                Text(modelLeft.map { "\($0)%" } ?? "–")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(modelLeft.map { GrazrStyle.tint(left: $0, threshold: model.flatMap(report.threshold(for:))) } ?? Theme.textTertiary)
                    .frame(width: modelColumnWidth, alignment: .trailing)
            }
            Text(status)
                .font(.system(size: 11, weight: account.id == next?.id ? .semibold : .regular))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: statusWidth, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func pinnedAgents(of account: GrazrAccount) -> [String] {
        report.pinnedPanes(for: account).map { agentNames[$0] ?? $0 }
    }

    private func futureRefill(of account: GrazrAccount) -> Date? {
        report.availableAt(account, now: now).flatMap { $0 > now ? $0 : nil }
    }

    private func status(of account: GrazrAccount) -> (String, Color) {
        if account.id == report.active {
            let eta = report.swapEstimate(for: account, now: now).flatMap { $0 > now ? $0 : nil }
            return (eta.map { String(localized: "active · ~\(GrazrStyle.time($0, now: now))") } ?? String(localized: "active"), Theme.statsAccount)
        }
        // Out of the shared rotation: the agents pinned to it have it to themselves.
        if report.heldAccountIDs.contains(account.id) {
            return (String(localized: "pinned · \(pinnedAgents(of: account).joined(separator: ", "))"), Theme.statsAccount)
        }
        if let block = report.block(for: account, now: now) {
            return (String(localized: "blocked: \(block.reason)"), Theme.danger)
        }
        if account.id == next?.id {
            guard let refill = futureRefill(of: account) else { return (String(localized: "NEXT ▸"), Theme.accent) }
            return (String(localized: "NEXT · refills \(GrazrStyle.time(refill, now: now))"), Theme.accent)
        }
        if !report.isListed(account) { return (String(localized: "not in ACCOUNTS"), Theme.textTertiary) }
        if account.windows.isEmpty { return (String(localized: "no reading yet"), Theme.textTertiary) }
        let low = account.windows.filter { window in
            guard let threshold = report.threshold(for: window), window.isOpen(now: now) else { return false }
            return window.remaining < threshold
        }
        if let refill = low.compactMap(\.resetsAt).max() {
            return (String(localized: "spent · resets \(GrazrStyle.time(refill, now: now))"), Theme.textTertiary)
        }
        return (String(localized: "ready"), Theme.textSecondary)
    }
}
