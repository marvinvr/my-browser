import SwiftUI

/// Layout constants for the window shell. Sidebar width is stored in UserDefaults under `sidebarWidth`.
///
/// Type, icons, and the rows that hold them live here. A row title is 14pt, one point above the
/// previous 13pt, and the icon box, row, favorites, and space bar follow that step.
nonisolated enum SidebarMetrics {
    static let widthDefaultsKey = "sidebarWidth"
    static let minWidth: Double = 180
    static let maxWidth: Double = 400
    static let defaultWidth: Double = 240
    static let contentInset: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    static let spaceTintOpacity: Double = 0.08
    static let navRowHeight: CGFloat = 28
    /// Site and folder rows. 32pt keeps the air a 30pt row had around a 16pt icon, now around 17pt.
    static let rowHeight: CGFloat = 32
    /// Row titles, the New Tab label, and inline rename. Was 13pt.
    static let rowTitle: CGFloat = 14
    /// Space name above the pinned list. Was 11pt.
    static let sectionHeader: CGFloat = 12
    /// Space-name block. Was 12pt of top padding under an 11pt label.
    static let sectionHeaderTop: CGFloat = 13
    static let sectionHeaderBottom: CGFloat = 2
    /// Empty-state copy under the space name. Was 12pt.
    static let secondaryText: CGFloat = 13
    /// Empty pinned hint. Was 28pt next to a 30pt row.
    static let emptyRowMinHeight: CGFloat = 30
    /// Hovered-row close mark. Was 9pt.
    static let closeGlyph: CGFloat = 10
    /// Close control. Was 22pt inside a 30pt row.
    static let closeHit: CGFloat = 24
    /// Favicon and folder box in a row. 17pt: an 18pt glyph crowds the 32pt row.
    static let rowIcon: CGFloat = 17
    /// Folder SF Symbol drawn inside `rowIcon`. Was 13pt in a 16pt box.
    static let folderSymbol: CGFloat = 14
    /// New Tab plus. Was 12pt.
    static let newTabSymbol: CGFloat = 13
    /// Hairline between panes in a split row. Was 12pt.
    static let splitDivider: CGFloat = 13
    /// Favorite glyph. The old 18pt icon scaled with the row icon (16 → 17).
    static let favoriteIcon: CGFloat = 19
    /// Favorite tile. Was 36pt, so the padding around the glyph stays the same.
    static let favoriteTileHeight: CGFloat = 38
    /// Space-bar symbol. Was 16pt.
    static let spaceSymbol: CGFloat = 17
    /// Space-bar hit target and chip. Was 26pt; the corner stays 8pt.
    static let spaceTarget: CGFloat = 28
    static let spaceCorner: CGFloat = 8
    /// Emoji in a space chip. Was 15pt.
    static let spaceEmoji: CGFloat = 16
    /// New-space plus. Was 14pt.
    static let spacePlus: CGFloat = 15
    /// Hide-sidebar glyph. Was 13pt. The circle stays `toolbarControl`.
    static let headerSymbol: CGFloat = 14
    /// Address field, matched to the row title so the URL is not the smaller of the two. Was 13pt.
    static let addressText: CGFloat = 14
    /// Link mark in the address field. Was 11pt.
    static let addressSymbol: CGFloat = 12
    /// Insecure lock beside the URL. Was 10pt.
    static let addressWarningSymbol: CGFloat = 11
    /// "Not Secure" beside the URL. Was 11pt.
    static let addressWarningText: CGFloat = 12
    /// Split-drop badge. Was 11pt.
    static let dropSplitSymbol: CGFloat = 12
    /// Back/forward/address bar above the page, including the progress line.
    static let toolbarHeight: CGFloat = 38
    /// Glass capsules inside the toolbar (navigation cluster and address field).
    static let toolbarControl: CGFloat = 26
    /// Hairline under the toolbar; the load progress draws in this band.
    static let progressHeight: CGFloat = 2
    /// Vertical centre of the traffic lights and the toolbar controls, measured from the top of the window.
    /// Shared by both address-bar positions so collapsing the sidebar does not move the lights.
    static let chromeCenterFromTop: CGFloat = contentInset + (toolbarHeight - progressHeight) / 2
    /// How far the traffic lights sit to the right of AppKit's titlebar position.
    /// A full-height sidebar wants the same inset Arc and Safari use, not the flush system default.
    static let trafficLightShiftX: CGFloat = 6
    /// Leading room the collapsed toolbar keeps clear for the traffic lights, including `trafficLightShiftX`.
    static let minimumTrafficClearance: CGFloat = 80
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
    /// Hover, selection, and reorder. A little slower than a disclosure.
    static let row = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let sidebar = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let space = Animation.spring(response: 0.34, dampingFraction: 0.9)
    static let selection = row
    static let list = row
    /// Folder open/close. No bounce, and short enough that the folder glyph and the rows below finish together.
    static let disclosure = Animation.spring(duration: 0.2, bounce: 0)
}
