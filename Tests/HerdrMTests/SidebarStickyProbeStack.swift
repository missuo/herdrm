import SwiftUI
@testable import herdrm

/// Shared frame sink for sticky-header probes (integration / visual / e2e).
/// Frames are in `.global` so a pinned header keeps a stable `minY` while the
/// content coordinate would keep drifting with scroll offset.
@MainActor
final class StickyProbeFrameStore: ObservableObject {
    var frames: [String: CGRect] = [:]
    var scrollFrame: CGRect = .zero
}

private struct StickyHeaderFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct StickyScrollFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Minimal LazyVStack+Section stack that mirrors Sidebar sticky pinning.
struct SidebarStickyProbeStack: View {
    let rowCountPerSection: Int
    let terminalsVisible: Bool
    var rowHeight: CGFloat = 32
    @ObservedObject var frames: StickyProbeFrameStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1, pinnedViews: SidebarStickyLayout.pinnedViews) {
                ForEach(
                    Array(SidebarStickyLayout.visibleSections(terminalsVisible: terminalsVisible).enumerated()),
                    id: \.element
                ) { index, section in
                    if index > 0 {
                        Color.clear.frame(height: SidebarStickyLayout.interSectionGap)
                    }
                    Section {
                        ForEach(0..<rowCountPerSection, id: \.self) { row in
                            Text("\(section.rawValue)-row-\(row)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: rowHeight)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: SidebarStickyLayout.headerHeight)
                            .padding(.horizontal, 8)
                            .background(.regularMaterial)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: StickyHeaderFrameKey.self,
                                        value: [section.accessibilityIdentifier: geo.frame(in: .global)]
                                    )
                                }
                            )
                            .accessibilityIdentifier(section.accessibilityIdentifier)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: StickyScrollFrameKey.self, value: geo.frame(in: .global))
            }
        )
        .onPreferenceChange(StickyHeaderFrameKey.self) { frames.frames = $0 }
        .onPreferenceChange(StickyScrollFrameKey.self) { frames.scrollFrame = $0 }
        .accessibilityIdentifier("sidebar.sticky.probe.scroll")
    }
}
