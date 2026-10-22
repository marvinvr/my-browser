import Foundation

/// Where the address field and back/forward/reload sit. Stored in UserDefaults.
nonisolated enum AddressBarPosition: String, CaseIterable, Identifiable, Sendable {
    case top
    case sidebar

    static let defaultsKey = "addressBarPosition"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: "Top"
        case .sidebar: "Sidebar"
        }
    }
}
