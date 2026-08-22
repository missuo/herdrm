import SwiftUI

enum SidebarMetrics {
    static let widthKey = "sidebar.width"
    static let defaultWidth: Double = 260
    static let minWidth: Double = 200
    static let maxWidth: Double = 520
    static let scaleKey = "sidebar.fontScale"
    static let defaultScale: Double = 1.0
}

struct SidebarScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var sidebarScale: CGFloat {
        get { self[SidebarScaleKey.self] }
        set { self[SidebarScaleKey.self] = newValue }
    }
}
