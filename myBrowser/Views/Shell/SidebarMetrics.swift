import SwiftUI

/// Layout constants for the window shell. Sidebar width is stored in UserDefaults under `sidebarWidth`.
enum SidebarMetrics {
    static let widthDefaultsKey = "sidebarWidth"
    static let minWidth: Double = 180
    static let maxWidth: Double = 400
    static let defaultWidth: Double = 240
    static let contentInset: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    static let spaceTintOpacity: Double = 0.08
    static let navRowHeight: CGFloat = 28
    static let rowHeight: CGFloat = 30
    /// Back/forward/address bar above the page, including the progress line.
    static let toolbarHeight: CGFloat = 38
    /// Glass capsules inside the toolbar (navigation cluster and address field).
    static let toolbarControl: CGFloat = 26
    /// Hairline under the toolbar; the load progress draws in this band.
    static let progressHeight: CGFloat = 2
    /// Vertical centre of the traffic lights and the toolbar controls, measured from the top of the window.
    /// Shared by both address-bar positions so collapsing the sidebar does not move the lights.
    static let chromeCenterFromTop: CGFloat = contentInset + (toolbarHeight - progressHeight) / 2
    /// Leading room the collapsed toolbar keeps clear for the traffic lights.
    static let minimumTrafficClearance: CGFloat = 74
}

/// Window coordinates of the traffic lights. `WindowConfigurator` keeps their centre on `chromeCenterFromTop`.
struct TrafficLightAnchor: Equatable {
    var clearance: CGFloat
    var centerFromTop: CGFloat

    static let fallback = TrafficLightAnchor(
        clearance: SidebarMetrics.minimumTrafficClearance,
        centerFromTop: SidebarMetrics.chromeCenterFromTop
    )
}

enum SidebarMotion {
    /// One spring for sidebar rows: hover, selection, reorder, and folder expand.
    static let row = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let sidebar = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let space = Animation.spring(response: 0.34, dampingFraction: 0.9)
    static let selection = row
    static let list = row
}
