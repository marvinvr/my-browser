import Foundation
import Observation

/// Per-window coordinator: selected space and tab, live tabs, and every user action
/// (menus, shortcuts, sidebar, command bar call into this).
@Observable
final class BrowserModel {
    enum CommandBarMode: Equatable {
        /// Cmd+T: result opens in a new tab.
        case newTab
        /// Cmd+L: prefilled with the current URL, result loads in the current tab.
        case editCurrent
    }

    let library: LibraryStore
    let session: SessionStore
    @ObservationIgnored let profiles = ProfileManager()

    /// Live tabs by item id.
    private(set) var tabs: [UUID: BrowserTab] = [:]
    private(set) var selectedSpaceID: UUID
    /// `nil` = command bar hidden.
    var commandBarMode: CommandBarMode?

    init(library: LibraryStore, session: SessionStore) {
        self.library = library
        self.session = session
        let fallback = library.ensureDefaultSpace().id
        selectedSpaceID = session.selectedSpaceID.flatMap { library.space($0)?.id } ?? fallback
    }

    // MARK: Derived

    var selectedSpace: Space? { library.space(selectedSpaceID) }
    var selectedItemID: UUID? { session.selectedItemBySpace[selectedSpaceID] }
    var selectedTab: BrowserTab? { selectedItemID.flatMap { tabs[$0] } }

    /// Items in sidebar order for the current space: favorites, pinned (depth-first, only expanded folders' children), tabs. Sites only.
    var navigableItems: [SidebarItem] {
        // TODO(worker B)
        []
    }

    // MARK: Spaces

    func selectSpace(_ id: UUID) {}
    func selectNextSpace() {}
    func selectPreviousSpace() {}
    @discardableResult func createSpace(name: String, symbol: String, color: SpaceColor) -> Space { library.createSpace(name: name, symbol: symbol, color: color) }
    func renameSpace(_ id: UUID, to name: String) {}
    func deleteSpace(_ id: UUID) {}

    // MARK: Tabs

    /// Selects an item: creates/loads its tab if needed.
    func select(_ itemID: UUID) {}
    /// Opens `url` in a new `.tabs` item of the current space (top of the list, Arc-style) and selects it unless in background.
    func openInNewTab(_ url: URL, inBackground: Bool = false) {}
    /// Loads `url` in the selected tab, or a new tab if none is selected.
    func openInCurrentTab(_ url: URL) {}
    /// Cmd+W.
    func closeSelectedTab() {}
    func close(_ itemID: UUID) {}
    /// Cmd+Shift+T.
    func reopenClosedTab() {}
    /// Cmd+1…8 (index 0…7); Cmd+9 passes `nil` = last.
    func selectItem(atIndex index: Int?) {}
    func selectNextTab() {}
    func selectPreviousTab() {}

    // MARK: Pinning / folders

    func pin(_ itemID: UUID) {}
    func unpin(_ itemID: UUID) {}
    func addToFavorites(_ itemID: UUID) {}
    func togglePinSelected() {}
    @discardableResult func createFolder(named name: String, parentID: UUID?) -> SidebarItem? { nil }
    func rename(_ itemID: UUID, to title: String) {}
    func toggleExpanded(_ folderID: UUID) {}

    // MARK: Sidebar / command bar

    func toggleSidebar() { session.isSidebarVisible.toggle() }
    func showCommandBar(_ mode: CommandBarMode) { commandBarMode = mode }
    func hideCommandBar() { commandBarMode = nil }

    /// Persist tab interaction states and flush stores (app termination).
    func saveState() {
        library.flush()
        session.flush()
    }
}
