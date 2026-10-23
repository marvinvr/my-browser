import Foundation

/// How long an unpinned tab can sit unselected before it is archived.
/// Stored in UserDefaults. Missing or unknown values resolve to 24 hours.
nonisolated enum TabArchiveInterval: String, CaseIterable, Identifiable, Sendable {
    case twelveHours = "12h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case never = "never"

    static let defaultsKey = "archiveTabsAfter"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twelveHours: "12 hours"
        case .twentyFourHours: "24 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .never: "Never"
        }
    }

    /// `nil` means do not archive.
    var duration: TimeInterval? {
        switch self {
        case .twelveHours: 12 * 60 * 60
        case .twentyFourHours: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        case .never: nil
        }
    }

    static let explanation = "Unpinned tabs you have not opened for this long are closed and kept in Archived Tabs for 30 days. Pinned tabs, favorites, the selected tab in each space, and tabs playing audio or video, in Picture in Picture, or downloading stay open."

    /// The saved choice, or 24 hours when the key is missing or not one of the known values.
    static var current: TabArchiveInterval {
        resolved(UserDefaults.standard.string(forKey: defaultsKey))
    }

    static func resolved(_ raw: String?) -> TabArchiveInterval {
        raw.flatMap(TabArchiveInterval.init(rawValue:)) ?? .twentyFourHours
    }
}
