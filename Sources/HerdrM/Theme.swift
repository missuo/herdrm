import AppKit
import HerdrKit
import SwiftUI

/// Design tokens from the herdrm design canvas (waku-derived), light/dark adaptive.
enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    // text ramp
    static let text = dynamic(hex(0x242424), hex(0xE2E2E2))
    static let textSecondary = dynamic(hex(0x666666), hex(0xA3A3A3))
    static let textTertiary = dynamic(hex(0x858585), hex(0x7D7D7D))
    static let textGhost = dynamic(hex(0xA4A4A4), hex(0x575757))

    // accent + status
    static let accent = dynamic(hex(0xC85F44), hex(0xE2795B))
    static let accentWash = dynamic(hex(0xC85F44, alpha: 0.12), hex(0xE2795B, alpha: 0.14))
    static let working = dynamic(hex(0x2563EB), hex(0x3B82F6))
    static let success = dynamic(hex(0x2FA35F), hex(0x62C987))
    static let warning = dynamic(hex(0xB8862E), hex(0xE0B36A))
    /// grazr's account line, matching the mint the Herdr TUI row uses (#b5ead7).
    static let statsAccount = dynamic(hex(0x3F9A7A), hex(0xB5EAD7))
    static let danger = dynamic(hex(0xC94F44), hex(0xE2726A))

    // surfaces
    static let itemWash = dynamic(hex(0x141414, alpha: 0.06), hex(0xF0F0F0, alpha: 0.06))
    static let itemWashSelected = dynamic(hex(0x141414, alpha: 0.07), hex(0xF0F0F0, alpha: 0.07))
    static let contentBackground = dynamic(hex(0xF6F6F6), hex(0x181818))
    static let terminalBackground = dynamic(hex(0xFFFFFF), hex(0x101012))
    static let statusBarBackground = dynamic(hex(0xF1F1F2), hex(0x141416))
    static let sidebarBorder = dynamic(hex(0xD9D9D9), hex(0x292929))
    static let hairline = dynamic(hex(0x000000, alpha: 0.08), hex(0xFFFFFF, alpha: 0.06))

    /// Distinct tints for device chips (deliberately avoids the status colors).
    static let devicePalette: [Color] = [
        dynamic(hex(0x7C3AED), hex(0x8B5CF6)),  // violet
        dynamic(hex(0x0D9488), hex(0x14B8A6)),  // teal
        dynamic(hex(0xBE185D), hex(0xEC4899)),  // magenta
        dynamic(hex(0x4338CA), hex(0x818CF8)),  // indigo
        dynamic(hex(0x92640C), hex(0xC9964A)),  // bronze
    ]

    /// Stable per-device tint; Local stays neutral.
    static func deviceTint(_ device: Device) -> Color {
        if device.isLocal { return textSecondary }
        let sum = device.id.uuidString.utf8.reduce(0) { $0 &+ Int($1) }
        return devicePalette[sum % devicePalette.count]
    }

    static func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .working: return working
        case .blocked: return warning
        case .done: return success
        case .idle, .unknown: return textGhost
        }
    }
}

/// Codex-style conversation marks: spinner while running, a filled unread
/// dot after a finish you have not opened, nothing once you have looked.
struct AgentStatusGlyph: View {
    let status: AgentStatus
    var unreadDone: Bool = false

    var body: some View {
        switch status {
        case .working:
            SpinnerView(color: Theme.working)
                .frame(width: 12, height: 12)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            if unreadDone {
                Circle()
                    .fill(Theme.working)
                    .frame(width: 7, height: 7)
            }
        case .idle, .unknown:
            EmptyView()
        }
    }
}

/// Space row uses the same glyph as an agent, for the strongest state inside.
struct SpaceAttentionGlyph: View {
    let attention: SpaceAttention

    var body: some View {
        switch attention {
        case .blocked:
            AgentStatusGlyph(status: .blocked)
        case .unreadDone:
            AgentStatusGlyph(status: .done, unreadDone: true)
        case .working:
            AgentStatusGlyph(status: .working)
        case .none:
            EmptyView()
        }
    }
}
