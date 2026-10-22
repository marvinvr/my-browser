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
}

/// Traffic-light geometry in the content view, so chrome can clear the buttons.
struct TrafficLightAnchor: Equatable {
    var clearance: CGFloat
    var centerFromTop: CGFloat

    static let fallback = TrafficLightAnchor(clearance: 78, centerFromTop: 20)
}

enum SidebarMotion {
    static let sidebar = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let space = Animation.spring(response: 0.34, dampingFraction: 0.9)
    static let selection = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let list = Animation.spring(response: 0.32, dampingFraction: 0.86)
}
