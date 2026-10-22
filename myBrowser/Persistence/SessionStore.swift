import Foundation
import Observation

/// Local-only session state (never synced): selection, per-tab back/forward history, closed tabs.
@Observable
final class SessionStore {
    struct ClosedTab: Codable, Hashable {
        var item: SidebarItem
        var interactionState: Data?
    }

    var selectedSpaceID: UUID? { didSet { didChange() } }
    var selectedItemBySpace: [UUID: UUID] = [:] { didSet { didChange() } }
    /// `WKWebView.interactionState` per tab id.
    var interactionStates: [UUID: Data] = [:] { didSet { didChange() } }
    /// Most recent last. Capped (TODO worker A: cap at 50).
    var closedTabs: [ClosedTab] = [] { didSet { didChange() } }
    var isSidebarVisible: Bool = true { didSet { didChange() } }

    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
        // TODO(worker A): load session.json.
    }

    func flush() {
        // TODO(worker A)
    }

    private func didChange() {
        // TODO(worker A): debounced save.
    }
}
