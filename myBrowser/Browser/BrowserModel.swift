import Foundation
import Observation
import WebKit

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

    private static let closedTabLimit = 50

    let library: LibraryStore
    let session: SessionStore
    @ObservationIgnored let profiles = ProfileManager()
    @ObservationIgnored let favicons: FaviconStore

    /// Live tabs by item id. Missing means the item is not loaded.
    private(set) var tabs: [UUID: BrowserTab] = [:]
    private(set) var selectedSpaceID: UUID
    /// `nil` = command bar hidden.
    var commandBarMode: CommandBarMode?

    init(library: LibraryStore, session: SessionStore) {
        self.library = library
        self.session = session
        favicons = FaviconStore(directory: library.directory)
        let fallback = library.ensureDefaultSpace().id
        let resolved = session.selectedSpaceID.flatMap { library.space($0)?.id } ?? fallback
        selectedSpaceID = resolved
        if session.selectedSpaceID != resolved {
            session.selectedSpaceID = resolved
        }
        if let itemID = session.selectedItemBySpace[resolved] {
            select(itemID)
        }
    }

    // MARK: Derived

    var selectedSpace: Space? { library.space(selectedSpaceID) }
    var selectedItemID: UUID? { session.selectedItemBySpace[selectedSpaceID] }
    var selectedTab: BrowserTab? { selectedItemID.flatMap { tabs[$0] } }

    /// Menu enablement for the selected tab. Stored here so command items observe this model,
    /// not a nested tab that `Commands` does not track.
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var canReload = false

    /// Sites in sidebar order for the current space: favorites, pinned (depth-first, expanded folders only), tabs.
    var navigableItems: [SidebarItem] {
        navigableItems(in: selectedSpaceID)
    }

    // MARK: Spaces

    func selectSpace(_ id: UUID) {
        guard library.space(id) != nil else { return }
        if selectedSpaceID != id { selectedSpaceID = id }
        if session.selectedSpaceID != id { session.selectedSpaceID = id }
        if let itemID = session.selectedItemBySpace[id] {
            select(itemID)
        } else {
            refreshNavigationState()
        }
    }

    func selectNextSpace() { moveSpace(by: 1) }
    func selectPreviousSpace() { moveSpace(by: -1) }

    @discardableResult
    func createSpace(name: String, symbol: String, color: SpaceColor) -> Space {
        let space = library.createSpace(name: name, symbol: symbol, color: color)
        selectSpace(space.id)
        return space
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard library.space(id) != nil else { return }
        library.updateSpace(id) { $0.name = name }
    }

    /// Refuses to delete the last remaining space. Selects the neighbour (next, else previous) and unloads the space's tabs.
    func deleteSpace(_ id: UUID) {
        let spaces = library.orderedSpaces
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let neighbour = spaces[index + 1 < spaces.count ? index + 1 : index - 1]
        let wasSelected = selectedSpaceID == id
        unloadTabs(in: id)
        session.selectedItemBySpace[id] = nil
        library.deleteSpace(id)
        if wasSelected {
            selectSpace(neighbour.id)
        }
    }

    // MARK: Tabs

    /// Selects an item and creates its live tab if needed. The web view itself is created by `BrowserTab.loadIfNeeded`.
    func select(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site else { return }
        if selectedSpaceID != item.spaceID {
            selectedSpaceID = item.spaceID
            if session.selectedSpaceID != item.spaceID {
                session.selectedSpaceID = item.spaceID
            }
        }
        if session.selectedItemBySpace[item.spaceID] != itemID {
            session.selectedItemBySpace[item.spaceID] = itemID
        }
        ensureTab(for: item).loadIfNeeded(using: profiles)
        refreshNavigationState()
    }

    /// Opens `url` in a new `.tabs` item at the top of the current space. Background leaves the selection alone.
    func openInNewTab(_ url: URL, inBackground: Bool = false) {
        guard let spaceID = selectedSpace?.id else { return }
        openInNewTab(url, spaceID: spaceID, inBackground: inBackground)
    }

    /// Loads `url` in the selected tab, or a new tab when nothing is selected.
    func openInCurrentTab(_ url: URL) {
        if let id = selectedItemID, library.item(id)?.kind == .site {
            select(id)
            tabs[id]?.load(url)
        } else {
            openInNewTab(url)
        }
    }

    /// Cmd+W.
    func closeSelectedTab() {
        guard let id = selectedItemID else { return }
        close(id)
    }

    func close(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site else { return }
        let spaceID = item.spaceID
        let wasSelected = session.selectedItemBySpace[spaceID] == itemID
        let order = navigableItems(in: spaceID)
        let index = order.firstIndex { $0.id == itemID }
        let state = capturedState(for: itemID)

        if item.section == .tabs {
            var snapshot = item
            if let tab = tabs[itemID] {
                if let liveURL = tab.url { snapshot.url = liveURL }
                if !tab.title.isEmpty { snapshot.title = tab.title }
            }
            session.closedTabs.append(SessionStore.ClosedTab(item: snapshot, interactionState: state))
            if session.closedTabs.count > Self.closedTabLimit {
                session.closedTabs.removeFirst(session.closedTabs.count - Self.closedTabLimit)
            }
            session.interactionStates[itemID] = nil
            library.deleteItem(itemID)
        } else if let state {
            session.interactionStates[itemID] = state
        }
        unloadTab(itemID)

        guard wasSelected else { return }
        if let index, let neighbour = neighbourID(in: order, closing: index) {
            select(neighbour)
        } else {
            session.selectedItemBySpace[spaceID] = nil
            if spaceID == selectedSpaceID { refreshNavigationState() }
        }
    }

    /// Removes an item for good. Unloads every site tab the deletion covers, moves the selection off those tabs, then deletes.
    /// Folders take their descendants with them. Unlike `close`, this does not remember a `.tabs` item for reopen.
    func delete(_ itemID: UUID) {
        guard let item = library.item(itemID) else { return }
        let spaceID = item.spaceID
        let removed = Set(containedSiteIDs(item))
        let order = navigableItems(in: spaceID)
        let selected = session.selectedItemBySpace[spaceID]
        let replacement = nextSelection(afterRemoving: removed, selected: selected, order: order)

        for id in removed {
            session.interactionStates[id] = nil
            unloadTab(id)
        }
        library.deleteItem(itemID)

        guard let selected, removed.contains(selected) else { return }
        if let replacement {
            select(replacement)
        } else {
            session.selectedItemBySpace[spaceID] = nil
            if spaceID == selectedSpaceID { refreshNavigationState() }
        }
    }

    /// Cmd+Shift+T. Restores the item at the top of `.tabs` with its back/forward history and selects it.
    func reopenClosedTab() {
        while let closed = session.closedTabs.last {
            session.closedTabs.removeLast()
            guard library.space(closed.item.spaceID) != nil else { continue }
            let item = library.restoreItem(closed.item, at: .start)
            if let state = closed.interactionState {
                session.interactionStates[item.id] = state
            }
            if selectedSpaceID != item.spaceID {
                selectedSpaceID = item.spaceID
                if session.selectedSpaceID != item.spaceID {
                    session.selectedSpaceID = item.spaceID
                }
            }
            select(item.id)
            return
        }
    }

    /// Cmd+1…8 (index 0…7). Cmd+9 passes `nil`, which selects the last navigable item.
    func selectItem(atIndex index: Int?) {
        let items = navigableItems
        guard !items.isEmpty else { return }
        if let index {
            guard items.indices.contains(index) else { return }
            select(items[index].id)
        } else {
            select(items[items.count - 1].id)
        }
    }

    func selectNextTab() { moveSelection(by: 1) }
    func selectPreviousTab() { moveSelection(by: -1) }

    // MARK: Pinning / folders

    /// Moves a `.tabs` item to the end of `.pinned`. The URL stays the page that's open.
    func pin(_ itemID: UUID) {
        guard let item = library.item(itemID), item.section == .tabs, item.kind == .site else { return }
        let url = tabs[itemID]?.url ?? item.url
        library.moveItem(itemID, to: .pinned, parentID: nil, at: .end)
        if let url, library.item(itemID)?.url != url {
            library.updateItem(itemID) { $0.url = url }
        }
    }

    /// Moves a pinned or favorite site to the top of `.tabs`.
    func unpin(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site, item.section != .tabs else { return }
        library.moveItem(itemID, to: .tabs, parentID: nil, at: .start)
    }

    func addToFavorites(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site, item.section != .favorites else { return }
        // A tab's URL is wherever it has navigated; a pin already has a home URL and we keep that.
        let url = item.section == .tabs ? (tabs[itemID]?.url ?? item.url) : item.url
        library.moveItem(itemID, to: .favorites, parentID: nil, at: .end)
        if let url, library.item(itemID)?.url != url {
            library.updateItem(itemID) { $0.url = url }
        }
    }

    /// Cmd+D. Pins the selected tab, or unpins a pinned/favorite site back to tabs.
    func togglePinSelected() {
        guard let id = selectedItemID, let item = library.item(id), item.kind == .site else { return }
        if item.section == .tabs {
            pin(id)
        } else {
            unpin(id)
        }
    }

    @discardableResult
    func createFolder(named name: String, parentID: UUID?) -> SidebarItem? {
        guard let spaceID = selectedSpace?.id else { return nil }
        if let parentID {
            guard let parent = library.item(parentID),
                  parent.spaceID == spaceID,
                  parent.section == .pinned,
                  parent.kind == .folder else { return nil }
        }
        return library.addItem(
            spaceID: spaceID,
            section: .pinned,
            kind: .folder,
            parentID: parentID,
            title: name,
            at: .end
        )
    }

    func rename(_ itemID: UUID, to title: String) {
        guard library.item(itemID) != nil else { return }
        library.updateItem(itemID) { $0.title = title }
    }

    func toggleExpanded(_ folderID: UUID) {
        guard let item = library.item(folderID), item.kind == .folder else { return }
        library.updateItem(folderID) { $0.isExpanded.toggle() }
    }

    // MARK: Sidebar / command bar

    func toggleSidebar() { session.isSidebarVisible.toggle() }
    func showCommandBar(_ mode: CommandBarMode) { commandBarMode = mode }
    func hideCommandBar() { commandBarMode = nil }

    /// window.open / target=_blank. The new web view uses `configuration` unchanged, is inserted at the top of `.tabs`, and is selected.
    @discardableResult
    func presentPopup(configuration: WKWebViewConfiguration, url: URL?, spaceID: UUID) -> WKWebView? {
        guard library.space(spaceID) != nil else { return nil }
        let pageURL = url.flatMap { BrowserTab.isPageURL($0) ? $0 : nil }
        let title = pageURL.map { Self.fallbackTitle(for: $0) } ?? "New Tab"
        let item = library.addItem(
            spaceID: spaceID,
            section: .tabs,
            kind: .site,
            title: title,
            url: pageURL,
            at: .start
        )
        let profileID = library.space(spaceID)?.profileID ?? spaceID
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let tab = BrowserTab(id: item.id, profileID: profileID, title: title, url: pageURL, adopting: webView)
        wire(tab, spaceID: spaceID)
        tabs[item.id] = tab
        if selectedSpaceID != spaceID {
            selectedSpaceID = spaceID
            if session.selectedSpaceID != spaceID {
                session.selectedSpaceID = spaceID
            }
        }
        select(item.id)
        return tab.webView
    }

    /// Persist tab interaction states and flush stores (app termination).
    func saveState() {
        for (id, tab) in tabs where tab.isLoaded {
            if let state = tab.interactionState {
                session.interactionStates[id] = state
            }
        }
        library.flush()
        session.flush()
    }

    // MARK: Private

    private func openInNewTab(_ url: URL, spaceID: UUID, inBackground: Bool) {
        guard library.space(spaceID) != nil else { return }
        let item = library.addItem(
            spaceID: spaceID,
            section: .tabs,
            kind: .site,
            title: Self.fallbackTitle(for: url),
            url: url,
            at: .start
        )
        guard !inBackground else { return }
        if selectedSpaceID != spaceID {
            selectedSpaceID = spaceID
            if session.selectedSpaceID != spaceID {
                session.selectedSpaceID = spaceID
            }
        }
        select(item.id)
    }

    private func ensureTab(for item: SidebarItem) -> BrowserTab {
        if let existing = tabs[item.id] { return existing }
        let profileID = library.space(item.spaceID)?.profileID ?? item.spaceID
        let tab = BrowserTab(
            id: item.id,
            profileID: profileID,
            url: item.url,
            title: item.title,
            interactionState: session.interactionStates[item.id]
        )
        wire(tab, spaceID: item.spaceID)
        tabs[item.id] = tab
        return tab
    }

    private func wire(_ tab: BrowserTab, spaceID: UUID) {
        tab.faviconStore = favicons
        tab.useCachedFavicon()
        tab.onOpenInNewTab = { [weak self] url, inBackground in
            self?.openInNewTab(url, spaceID: spaceID, inBackground: inBackground)
        }
        tab.onCreateWebView = { [weak self] configuration, url in
            self?.presentPopup(configuration: configuration, url: url, spaceID: spaceID)
        }
        tab.onStateChange = { [weak self] tab in
            self?.mirror(tab)
        }
        tab.onNavigationChange = { [weak self] tab in
            guard tab.id == self?.selectedItemID else { return }
            self?.refreshNavigationState()
        }
    }

    private func refreshNavigationState() {
        let tab = selectedTab
        let back = tab?.canGoBack == true
        let forward = tab?.canGoForward == true
        let reload = tab != nil
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
        if canReload != reload { canReload = reload }
        NavigationCommands.apply(self)
    }

    /// Tabs mirror the live URL and title. Pinned and favorite items keep the title and URL the user saved.
    private func mirror(_ tab: BrowserTab) {
        guard let item = library.item(tab.id), item.section == .tabs else { return }
        let title = tab.title.isEmpty ? item.title : tab.title
        let url = tab.url ?? item.url
        guard title != item.title || url != item.url else { return }
        library.updateItem(tab.id) {
            $0.title = title
            $0.url = url
        }
    }

    private func capturedState(for itemID: UUID) -> Data? {
        if let tab = tabs[itemID], tab.isLoaded {
            return tab.interactionState ?? session.interactionStates[itemID]
        }
        return session.interactionStates[itemID]
    }

    private func unloadTab(_ id: UUID) {
        tabs[id]?.unload()
        tabs[id] = nil
    }

    private func unloadTabs(in spaceID: UUID) {
        let ids = library.items.values.filter { $0.spaceID == spaceID }.map(\.id)
        for id in ids {
            unloadTab(id)
            session.interactionStates[id] = nil
        }
    }

    private func navigableItems(in spaceID: UUID) -> [SidebarItem] {
        guard library.space(spaceID) != nil else { return [] }
        var items: [SidebarItem] = []
        items.append(contentsOf: library.children(of: nil, section: .favorites, in: spaceID).filter { $0.kind == .site })
        var visited: Set<UUID> = []
        items.append(contentsOf: pinnedSites(in: spaceID, parentID: nil, visited: &visited))
        items.append(contentsOf: library.children(of: nil, section: .tabs, in: spaceID).filter { $0.kind == .site })
        return items
    }

    private func pinnedSites(in spaceID: UUID, parentID: UUID?, visited: inout Set<UUID>) -> [SidebarItem] {
        var result: [SidebarItem] = []
        for child in library.children(of: parentID, section: .pinned, in: spaceID) {
            guard visited.insert(child.id).inserted else { continue }
            switch child.kind {
            case .site:
                result.append(child)
            case .folder where child.isExpanded:
                result.append(contentsOf: pinnedSites(in: spaceID, parentID: child.id, visited: &visited))
            case .folder:
                break
            }
        }
        return result
    }

    /// Site ids `delete` will remove: the item itself, or every site under a folder.
    private func containedSiteIDs(_ root: SidebarItem) -> [UUID] {
        if root.kind == .site { return [root.id] }
        var byParent: [UUID: [SidebarItem]] = [:]
        for item in library.items.values where item.deletedAt == nil && item.spaceID == root.spaceID {
            if let parentID = item.parentID {
                byParent[parentID, default: []].append(item)
            }
        }
        var sites: [UUID] = []
        var queue = byParent[root.id] ?? []
        var seen: Set<UUID> = [root.id]
        var index = 0
        while index < queue.count {
            let item = queue[index]
            index += 1
            guard seen.insert(item.id).inserted else { continue }
            if item.kind == .site { sites.append(item.id) }
            if let children = byParent[item.id] {
                queue.append(contentsOf: children)
            }
        }
        return sites
    }

    /// Nearest surviving navigable item when `selected` is among `removed`.
    private func nextSelection(afterRemoving removed: Set<UUID>, selected: UUID?, order: [SidebarItem]) -> UUID? {
        guard let selected, removed.contains(selected) else { return nil }
        guard let index = order.firstIndex(where: { $0.id == selected }) else {
            return order.first { !removed.contains($0.id) }?.id
        }
        if let next = order[(index + 1)...].first(where: { !removed.contains($0.id) }) {
            return next.id
        }
        guard index > 0 else { return nil }
        return order[..<index].last(where: { !removed.contains($0.id) })?.id
    }

    /// Next item below, else the one above. `index` is the position in the pre-close list.
    private func neighbourID(in items: [SidebarItem], closing index: Int) -> UUID? {
        if index + 1 < items.count { return items[index + 1].id }
        if index > 0 { return items[index - 1].id }
        return nil
    }

    private func moveSelection(by delta: Int) {
        let items = navigableItems
        guard !items.isEmpty else { return }
        let current = selectedItemID.flatMap { id in items.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = (current + delta + items.count) % items.count
        } else {
            next = delta > 0 ? 0 : items.count - 1
        }
        select(items[next].id)
    }

    private func moveSpace(by delta: Int) {
        let spaces = library.orderedSpaces
        guard !spaces.isEmpty else { return }
        let index = spaces.firstIndex { $0.id == selectedSpaceID } ?? 0
        let next = (index + delta + spaces.count) % spaces.count
        selectSpace(spaces[next].id)
    }

    private static func fallbackTitle(for url: URL) -> String {
        if let host = url.host(), !host.isEmpty { return host }
        let absolute = url.absoluteString
        return absolute.isEmpty ? "New Tab" : absolute
    }
}
