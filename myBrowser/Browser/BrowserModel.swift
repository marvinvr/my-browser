import Foundation
import Observation
import SwiftUI
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
    let downloads: DownloadManager
    /// Web extensions for this window. Nil in tests and previews.
    @ObservationIgnored weak var extensions: ExtensionManager?

    /// Live tabs by item id. Missing means the item is not loaded.
    private(set) var tabs: [UUID: BrowserTab] = [:]
    /// Splits this window has already shown. The first show loads every pane.
    /// A later focus change loads the focused pane only.
    @ObservationIgnored private var presentedSplitIDs: Set<UUID> = []
    enum SpaceSwitchDirection: Equatable {
        case previous
        case next
    }

    private(set) var selectedSpaceID: UUID
    /// Direction of the last space change. Steps from `selectNextSpace` / `selectPreviousSpace`
    /// keep their command direction, so a wrap off the last space still slides forward.
    private(set) var lastSpaceSwitchDirection: SpaceSwitchDirection = .next
    /// `nil` = command bar hidden.
    var commandBarMode: CommandBarMode?
    /// Bumped when the bar should open fresh, even if `commandBarMode` did not change.
    private(set) var commandBarGeneration = 0
    /// File → Import… presents the import sheet from the main window.
    var isPresentingImport = false
    /// History → Archived Tabs… presents the archive sheet.
    var isPresentingArchive = false

    init(library: LibraryStore, session: SessionStore, extensions: ExtensionManager? = nil) {
        self.library = library
        self.session = session
        favicons = FaviconStore(directory: library.directory)
        downloads = DownloadManager(directory: library.directory)
        self.extensions = extensions
        let fallback = library.ensureDefaultSpace().id
        let resolved = session.selectedSpaceID.flatMap { library.space($0)?.id } ?? fallback
        selectedSpaceID = resolved
        if session.selectedSpaceID != resolved {
            session.selectedSpaceID = resolved
        }
        downloads.visibleProfileID = library.space(resolved)?.profileID ?? resolved
        downloads.webViewProvider = { [weak self] profileID in
            self?.webViewForDownloads(profileID)
        }
        profiles.extensionController = { [weak extensions] profileID in
            extensions?.controller(for: profileID)
        }
        if let itemID = session.selectedItemBySpace[resolved] {
            select(itemID)
        }
        installPictureInPictureMonitoring()
    }

    deinit {
        archiveLoop?.cancel()
        for token in pictureInPictureObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in archiveObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: Derived

    var selectedSpace: Space? { library.space(selectedSpaceID) }
    var selectedItemID: UUID? { session.selectedItemBySpace[selectedSpaceID] }
    /// The site the toolbar drives. When the selection is a split, this is the focused pane.
    var selectedTab: BrowserTab? {
        guard let id = selectedItemID, let item = library.item(id) else { return nil }
        switch item.kind {
        case .site:
            return tabs[id]
        case .split:
            guard let focus = resolvedFocus(in: id) else { return nil }
            return tabs[focus]
        case .folder:
            return nil
        }
    }
    /// Row the keyboard acts on. A folder can be focused while the open tab stays loaded.
    var sidebarFocusID: UUID?
    /// Site rows read this instead of the library, so a folder toggle does not redraw every row.
    private(set) var sidebarFocusIsFolder = false

    /// Menu enablement for the selected tab. Stored here so command items observe this model,
    /// not a nested tab that `Commands` does not track.
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var canReload = false
    /// Bumped when the current page URL is copied, so address fields can flash a checkmark.
    private(set) var linkCopyGeneration = 0
    /// Selected tab can enter or leave Picture in Picture. Menus observe these, not the tab.
    private(set) var canPictureInPicture = false
    private(set) var pictureInPictureActive = false
    /// Tab whose video is in the system PiP panel, including while enter is still starting.
    var pictureInPictureTabID: UUID?
    @ObservationIgnored var pictureInPictureSession: PictureInPictureSession?
    @ObservationIgnored var pictureInPictureForegroundID: UUID?
    @ObservationIgnored var pictureInPictureEnterGeneration = 0
    @ObservationIgnored var pictureInPictureIgnoreFocusUntil = Date.distantPast
    @ObservationIgnored var pictureInPictureWindowFocused: Bool?
    @ObservationIgnored var pictureInPictureFocusTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) var pictureInPictureObservers: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) var archiveObservers: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) var archiveLoop: Task<Void, Never>?

    /// Sites in sidebar order: favorites, pinned (depth-first, expanded folders only), tabs.
    /// A split is replaced by its panes, so each page is one stop and the container is not a second one.
    var navigableItems: [SidebarItem] {
        navigableItems(in: selectedSpaceID)
    }

    // MARK: Spaces

    func selectSpace(_ id: UUID) {
        guard library.space(id) != nil else { return }
        adoptSpace(id)
        if let itemID = session.selectedItemBySpace[id] {
            select(itemID)
        } else {
            refreshNavigationState()
            syncPictureInPictureForeground()
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
    ///
    /// A split selects that row and shows its panes. A member selects the split and focuses that pane.
    func select(_ itemID: UUID) {
        guard let item = library.item(itemID) else { return }
        // The tab being left was viewed until this moment, so its idle time starts now.
        // A split stamps its unpinned panes too, because the selected row is the container.
        if let previous = session.selectedItemBySpace[item.spaceID], previous != itemID {
            noteViewed(previous)
        }
        noteViewed(itemID)
        if item.isSplit {
            selectSplit(item, focus: nil)
            return
        }
        if item.kind == .site, let split = library.splitContainer(of: itemID) {
            selectSplit(split, focus: itemID)
            return
        }
        guard item.kind == .site else { return }
        setSidebarFocus(itemID)
        let previous = selectedTab
        if selectedSpaceID != item.spaceID {
            adoptSpace(item.spaceID)
        }
        if session.selectedItemBySpace[item.spaceID] != itemID {
            session.selectedItemBySpace[item.spaceID] = itemID
        }
        let tab = ensureTab(for: item)
        let created = !tab.isLoaded
        tab.loadIfNeeded(using: profiles)
        if created {
            extensions?.tabOpened(tab)
        }
        if previous?.id != tab.id {
            extensions?.tabActivated(tab, previous: previous)
        }
        refreshNavigationState()
        syncPictureInPictureForeground()
    }

    /// Selects a split. `focus` nil keeps the stored pane, or the first pane when that id is gone.
    /// The first time the split is shown, every pane loads. A focus change loads the focused pane
    /// and leaves an unloaded sibling alone.
    private func selectSplit(_ split: SidebarItem, focus requested: UUID?) {
        let members = library.splitMembers(of: split.id)
        guard !members.isEmpty else { return }
        let focus: UUID
        if let requested, members.contains(where: { $0.id == requested }) {
            focus = requested
        } else if let stored = session.focusedPaneBySplit[split.id], members.contains(where: { $0.id == stored }) {
            focus = stored
        } else {
            focus = members[0].id
        }
        let alreadySelected = session.selectedItemBySpace[split.spaceID] == split.id
        let previous = selectedTab
        session.focusedPaneBySplit[split.id] = focus
        setSidebarFocus(split.id)
        if selectedSpaceID != split.spaceID {
            adoptSpace(split.spaceID)
        }
        if !alreadySelected {
            session.selectedItemBySpace[split.spaceID] = split.id
        }
        // Relaunch already has the split selected and an empty presented set, so that still loads every pane.
        // Closing a pinned pane while the split stays selected does not, so the closed pane stays unloaded.
        let firstShow = !alreadySelected || !presentedSplitIDs.contains(split.id)
        presentedSplitIDs.insert(split.id)
        for member in members {
            let keepLoaded = tabs[member.id]?.isLoaded == true
            guard member.id == focus || keepLoaded || firstShow else { continue }
            let tab = ensureTab(for: member)
            let created = !tab.isLoaded
            tab.loadIfNeeded(using: profiles)
            if created { extensions?.tabOpened(tab) }
        }
        if let focused = tabs[focus], previous?.id != focused.id {
            extensions?.tabActivated(focused, previous: previous)
        }
        refreshNavigationState()
        // Moving between panes that are still on screen must not send the other pane to Picture in Picture.
        // Leaving a tab that this split does not show still does.
        let previousStillVisible = previous.map { tab in members.contains { $0.id == tab.id } } ?? false
        if previousStillVisible {
            pictureInPictureForegroundID = focus
        } else {
            syncPictureInPictureForeground()
        }
    }

    /// Stamps `itemID` as viewed. A split also stamps its unpinned panes, which stay on screen while that row is selected.
    private func noteViewed(_ itemID: UUID, at date: Date = .now) {
        session.lastActiveAt[itemID] = date
        guard library.item(itemID)?.isSplit == true else { return }
        for member in library.splitMembers(of: itemID) where member.section == .tabs {
            session.lastActiveAt[member.id] = date
        }
    }

    /// Opens `url` in a new `.tabs` item at the top of the current space. Background leaves the selection alone.
    /// `httpsFirst` may fall back to HTTP once if that load fails.
    func openInNewTab(_ url: URL, inBackground: Bool = false, httpsFirst: Bool = false) {
        guard let spaceID = selectedSpace?.id else { return }
        openInNewTab(url, spaceID: spaceID, inBackground: inBackground, httpsFirst: httpsFirst)
    }

    /// Loads `url` in the selected tab (the focused pane, when a split is selected), or a new tab.
    /// `httpsFirst` may fall back to HTTP once if that load fails.
    func openInCurrentTab(_ url: URL, httpsFirst: Bool = false) {
        if let tab = selectedTab {
            select(tab.id)
            tab.load(url, httpsFirst: httpsFirst)
        } else {
            openInNewTab(url, httpsFirst: httpsFirst)
        }
    }

    /// Cmd+W.
    func closeSelectedTab() {
        guard let id = selectedItemID else { return }
        close(id)
    }

    func close(_ itemID: UUID) {
        close(itemID, archivingAt: nil)
    }

    /// `archivingAt` also records the tab in Archived Tabs. Manual closes pass nil.
    /// Closing a split closes its focused pane. Closing a pane leaves the split, and dissolves it at one member.
    func close(_ itemID: UUID, archivingAt: Date?) {
        guard let item = library.item(itemID) else { return }
        if item.isSplit {
            guard let focus = resolvedFocus(in: item.id) else { return }
            close(focus, archivingAt: archivingAt)
            return
        }
        if item.kind == .site, let split = library.splitContainer(of: itemID) {
            closeSplitMember(item, split: split, archivingAt: archivingAt)
            return
        }
        guard item.kind == .site else { return }
        let spaceID = item.spaceID
        let wasSelected = session.selectedItemBySpace[spaceID] == itemID
        let order = navigableItems(in: spaceID)
        let index = order.firstIndex { $0.id == itemID }

        if PinnedPage.recordsLiveURL(in: item.section) {
            let state = capturedState(for: itemID)
            var snapshot = item
            if let tab = tabs[itemID] {
                if let liveURL = tab.url { snapshot.url = liveURL }
                if !tab.title.isEmpty { snapshot.title = tab.title }
            }
            session.closedTabs.append(SessionStore.ClosedTab(item: snapshot, interactionState: state))
            if session.closedTabs.count > Self.closedTabLimit {
                session.closedTabs.removeFirst(session.closedTabs.count - Self.closedTabLimit)
            }
            if let archivingAt {
                session.archivedTabs.removeAll { $0.item.id == itemID }
                session.archivedTabs.append(SessionStore.ArchivedTab(
                    item: snapshot,
                    interactionState: state,
                    archivedAt: archivingAt,
                    lastActiveAt: session.lastActiveAt[itemID] ?? archivingAt
                ))
            }
            session.lastActiveAt[itemID] = nil
            session.interactionStates[itemID] = nil
            library.deleteItem(itemID)
        } else {
            // Closing a pin unloads it and forgets the away page. The next open loads `item.url`.
            session.interactionStates[itemID] = nil
        }
        unloadTab(itemID)
        if sidebarFocusID == itemID { setSidebarFocus(nil) }

        guard wasSelected else { return }
        if let index, let neighbour = neighbourID(in: order, closing: index) {
            select(neighbour)
        } else {
            session.selectedItemBySpace[spaceID] = nil
            if spaceID == selectedSpaceID {
                refreshNavigationState()
                syncPictureInPictureForeground()
            }
        }
    }

    /// Close one pane. A tabs pane is removed and remembered for reopen. A pinned pane unloads and stays.
    /// A pinned pane with no saved URL is deleted only when the live tab has no URL either. A page
    /// loaded into that blank pane is stored as its home URL, then the pane unloads like any other pin.
    /// Removing a tabs pane dissolves the split when one member would be left.
    /// `archivingAt` also records a tabs pane in Archived Tabs.
    private func closeSplitMember(_ item: SidebarItem, split: SidebarItem, archivingAt: Date? = nil) {
        let members = library.splitMembers(of: split.id)
        let wasFocused = resolvedFocus(in: split.id) == item.id
        let splitSelected = session.selectedItemBySpace[split.spaceID] == split.id
        let state = capturedState(for: item.id)

        if item.section == .tabs {
            var snapshot = item
            snapshot.parentID = nil
            snapshot.splitFraction = nil
            if let tab = tabs[item.id] {
                if let liveURL = tab.url { snapshot.url = liveURL }
                if !tab.title.isEmpty { snapshot.title = tab.title }
            }
            session.closedTabs.append(SessionStore.ClosedTab(item: snapshot, interactionState: state))
            if session.closedTabs.count > Self.closedTabLimit {
                session.closedTabs.removeFirst(session.closedTabs.count - Self.closedTabLimit)
            }
            if let archivingAt {
                session.archivedTabs.removeAll { $0.item.id == item.id }
                session.archivedTabs.append(SessionStore.ArchivedTab(
                    item: snapshot,
                    interactionState: state,
                    archivedAt: archivingAt,
                    lastActiveAt: session.lastActiveAt[item.id] ?? archivingAt
                ))
            }
            session.lastActiveAt[item.id] = nil
            session.interactionStates[item.id] = nil
            library.deleteItem(item.id)
        } else if item.url == nil, tabs[item.id]?.url == nil {
            // A blank pane opened into a pin has no home URL and has not loaded a page.
            // Unloading it would leave "New Tab" in the row.
            session.interactionStates[item.id] = nil
            library.deleteItem(item.id)
        } else {
            if item.url == nil, let tab = tabs[item.id], let liveURL = tab.url {
                // Opened blank, then the user loaded a page. That page becomes the pin's home.
                let title = PinnedPage.replacementTitle(saved: item.title, current: tab.title, url: liveURL)
                library.updateItem(item.id) {
                    $0.url = liveURL
                    $0.title = title
                }
            }
            // Closing a pinned pane unloads it and forgets the away page. The next open loads `item.url`.
            // Pins are not added to recently closed, same as closing a loose pin.
            session.interactionStates[item.id] = nil
        }
        unloadTab(item.id)
        if sidebarFocusID == item.id { setSidebarFocus(split.id) }
        noteSplitMemberRemoved(itemID: item.id, split: split, members: members, wasFocused: wasFocused, splitSelected: splitSelected)
    }

    /// Deletes one pane for good (no reopen entry) and dissolves the split at one member.
    private func deleteSplitMember(_ item: SidebarItem, split: SidebarItem) {
        let members = library.splitMembers(of: split.id)
        let wasFocused = resolvedFocus(in: split.id) == item.id
        let splitSelected = session.selectedItemBySpace[split.spaceID] == split.id
        session.interactionStates[item.id] = nil
        unloadTab(item.id)
        if sidebarFocusID == item.id { setSidebarFocus(nil) }
        library.deleteItem(item.id)
        noteSplitMemberRemoved(itemID: item.id, split: split, members: members, wasFocused: wasFocused, splitSelected: splitSelected)
    }

    private func noteSplitMemberRemoved(
        itemID: UUID,
        split: SidebarItem,
        members: [SidebarItem],
        wasFocused: Bool,
        splitSelected: Bool
    ) {
        let splitLive = library.item(split.id)?.isSplit == true
        if splitLive {
            if wasFocused, let next = neighbourMember(in: members, closing: itemID, remaining: library.splitMembers(of: split.id)) {
                session.focusedPaneBySplit[split.id] = next.id
            }
            if splitSelected, split.spaceID == selectedSpaceID {
                select(split.id)
            }
            return
        }
        session.focusedPaneBySplit[split.id] = nil
        guard splitSelected else { return }
        let survivor = members.first { $0.id != itemID && library.item($0.id) != nil }
        if split.spaceID == selectedSpaceID {
            if let survivor {
                select(survivor.id)
            } else {
                session.selectedItemBySpace[split.spaceID] = nil
                refreshNavigationState()
            }
        } else {
            session.selectedItemBySpace[split.spaceID] = survivor?.id
        }
    }

    /// The next remaining pane after `id`, else the previous one.
    private func neighbourMember(in old: [SidebarItem], closing id: UUID, remaining: [SidebarItem]) -> SidebarItem? {
        guard let index = old.firstIndex(where: { $0.id == id }) else { return remaining.first }
        let contains: (SidebarItem) -> Bool = { candidate in remaining.contains { $0.id == candidate.id } }
        if let next = old[(index + 1)...].first(where: contains) {
            return remaining.first { $0.id == next.id }
        }
        if index > 0, let previous = old[..<index].last(where: contains) {
            return remaining.first { $0.id == previous.id }
        }
        return remaining.first
    }

    /// Removes an item for good. Unloads every site tab the deletion covers, moves the selection off those tabs, then deletes.
    /// Folders take their descendants with them. A split takes its members (pinned: tombstones, tabs: hard-delete).
    /// Unlike `close`, this does not remember a `.tabs` item for reopen.
    func delete(_ itemID: UUID) {
        guard let item = library.item(itemID) else { return }
        if item.kind == .site, let split = library.splitContainer(of: itemID) {
            deleteSplitMember(item, split: split)
            return
        }
        let spaceID = item.spaceID
        let subtree = Set([item.id] + library.descendantIDs(of: item.id, spaceID: spaceID))
        let removed = Set(containedSiteIDs(item))
        let order = navigableItems(in: spaceID)
        let selected = session.selectedItemBySpace[spaceID]
        let anchor = navigableAnchor(for: selected)
        let replacement = nextSelection(afterRemoving: removed, selected: anchor, order: order)

        for id in removed {
            session.interactionStates[id] = nil
            session.lastActiveAt[id] = nil
            unloadTab(id)
        }
        if let focus = sidebarFocusID, focus == itemID || subtree.contains(focus) || removed.contains(focus) {
            setSidebarFocus(nil)
        }
        session.focusedPaneBySplit = session.focusedPaneBySplit.filter { !subtree.contains($0.key) }
        library.deleteItem(itemID)

        let selectionHit = selected.map { subtree.contains($0) || removed.contains($0) } ?? false
        guard selectionHit else { return }
        if let replacement {
            select(replacement)
        } else {
            session.selectedItemBySpace[spaceID] = nil
            if spaceID == selectedSpaceID {
                refreshNavigationState()
                syncPictureInPictureForeground()
            }
        }
    }

    /// Cmd+Shift+T. Restores the item at the top of `.tabs` with its back/forward history and selects it.
    /// An archived tab reopened this way leaves the archive, so it is not listed twice.
    func reopenClosedTab() {
        while let closed = session.closedTabs.last {
            session.closedTabs.removeLast()
            session.archivedTabs.removeAll { $0.item.id == closed.item.id }
            guard restoreClosed(closed.item, interactionState: closed.interactionState) else { continue }
            return
        }
    }

    /// Puts an archived tab back at the top of its space and selects it.
    func reopenArchivedTab(_ id: UUID) {
        guard let index = session.archivedTabs.lastIndex(where: { $0.item.id == id }) else { return }
        let archived = session.archivedTabs.remove(at: index)
        session.closedTabs.removeAll { $0.item.id == id }
        _ = restoreClosed(archived.item, interactionState: archived.interactionState)
    }

    @discardableResult
    private func restoreClosed(_ snapshot: SidebarItem, interactionState: Data?) -> Bool {
        guard library.space(snapshot.spaceID) != nil else { return false }
        let item = library.restoreItem(snapshot, at: .start)
        if let interactionState {
            session.interactionStates[item.id] = interactionState
        }
        if selectedSpaceID != item.spaceID {
            adoptSpace(item.spaceID)
        }
        select(item.id)
        return true
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

    /// Moves a `.tabs` site or split to the end of `.pinned`. The URL stays the page that's open.
    /// Pinning one pane pulls that site out of its split.
    func pin(_ itemID: UUID) {
        guard let item = library.item(itemID), item.section == .tabs else { return }
        if item.isSplit {
            for member in library.splitMembers(of: item.id) {
                if let live = tabs[member.id]?.url, member.url != live {
                    library.updateItem(member.id) { $0.url = live }
                }
            }
            library.moveItem(item.id, to: .pinned, parentID: nil, at: .end)
            return
        }
        guard item.kind == .site else { return }
        let sourceSplit = library.splitContainer(of: itemID)?.id
        let previous = sourceSplit.map { library.splitMembers(of: $0).map(\.id) } ?? []
        let wasFocused = sourceSplit.flatMap { resolvedFocus(in: $0) } == itemID
        let splitSelected = sourceSplit.map { session.selectedItemBySpace[item.spaceID] == $0 } ?? false
        let url = tabs[itemID]?.url ?? item.url
        library.moveItem(itemID, to: .pinned, parentID: nil, at: .end)
        if let url, library.item(itemID)?.url != url {
            library.updateItem(itemID) { $0.url = url }
        }
        if let tab = tabs[itemID] { extensions?.tabPropertiesChanged(tab) }
        if let sourceSplit {
            repairSplit(
                splitID: sourceSplit,
                detachedID: itemID,
                previousMemberIDs: previous,
                selectDetached: splitSelected && wasFocused
            )
        }
    }

    /// Moves a pinned or favorite site, or a whole split, to the top of `.tabs`.
    /// Unpinning one pane pulls that site out of its split.
    func unpin(_ itemID: UUID) {
        guard let item = library.item(itemID), item.section != .tabs else { return }
        if item.isSplit {
            library.moveItem(itemID, to: .tabs, parentID: nil, at: .start)
            return
        }
        guard item.kind == .site else { return }
        let sourceSplit = library.splitContainer(of: itemID)?.id
        let previous = sourceSplit.map { library.splitMembers(of: $0).map(\.id) } ?? []
        let wasFocused = sourceSplit.flatMap { resolvedFocus(in: $0) } == itemID
        let splitSelected = sourceSplit.map { session.selectedItemBySpace[item.spaceID] == $0 } ?? false
        library.moveItem(itemID, to: .tabs, parentID: nil, at: .start)
        if let tab = tabs[itemID] { extensions?.tabPropertiesChanged(tab) }
        if let sourceSplit {
            repairSplit(
                splitID: sourceSplit,
                detachedID: itemID,
                previousMemberIDs: previous,
                selectDetached: splitSelected && wasFocused
            )
        }
    }

    func addToFavorites(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site, item.section != .favorites else { return }
        let sourceSplit = library.splitContainer(of: itemID)?.id
        let previous = sourceSplit.map { library.splitMembers(of: $0).map(\.id) } ?? []
        let wasFocused = sourceSplit.flatMap { resolvedFocus(in: $0) } == itemID
        let splitSelected = sourceSplit.map { session.selectedItemBySpace[item.spaceID] == $0 } ?? false
        // A tab's URL is wherever it has navigated; a pin already has a home URL and we keep that.
        let url = item.section == .tabs ? (tabs[itemID]?.url ?? item.url) : item.url
        library.moveItem(itemID, to: .favorites, parentID: nil, at: .end)
        if let url, library.item(itemID)?.url != url {
            library.updateItem(itemID) { $0.url = url }
        }
        if let sourceSplit {
            repairSplit(
                splitID: sourceSplit,
                detachedID: itemID,
                previousMemberIDs: previous,
                selectDetached: splitSelected && wasFocused
            )
        }
    }

    /// Loaded pin or favorite whose page is not the saved URL.
    func isPinnedAway(_ itemID: UUID) -> Bool {
        guard let item = library.item(itemID) else { return false }
        return SidebarTitle.isAway(item, tab: tabs[itemID])
    }

    /// Loads the saved URL in the pin. A new load, not a walk back through history.
    func returnToPinnedURL(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site, !PinnedPage.recordsLiveURL(in: item.section) else { return }
        let tab = tabs[itemID]
        let before = PinnedPage.State(
            savedURL: item.url,
            savedTitle: item.title,
            currentURL: tab?.url,
            currentTitle: tab?.title ?? "",
            loaded: tab?.isLoaded == true,
            hasInteractionState: session.interactionStates[itemID] != nil
        )
        let after = PinnedPage.returnHome(before)
        select(itemID)
        guard after.currentURL != before.currentURL, let url = after.currentURL else { return }
        session.interactionStates[itemID] = nil
        tabs[itemID]?.load(url)
    }

    /// Saves the page that is open as the pin's URL and title. No-op unless that page is away.
    /// One `updateItem`, so sync sees a single record change (`modifiedAt` included).
    /// The favicon is the host cache the live tab already filled; the item has no icon field.
    func replacePinnedURLWithCurrent(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site, !PinnedPage.recordsLiveURL(in: item.section) else { return }
        guard let tab = tabs[itemID], tab.isLoaded else { return }
        let before = PinnedPage.State(
            savedURL: item.url,
            savedTitle: item.title,
            currentURL: tab.url,
            currentTitle: tab.title,
            loaded: true,
            hasInteractionState: session.interactionStates[itemID] != nil
        )
        let after = PinnedPage.replaceWithCurrent(before)
        guard after.savedURL != before.savedURL || after.savedTitle != before.savedTitle else { return }
        library.updateItem(itemID) {
            $0.url = after.savedURL
            $0.title = after.savedTitle
        }
    }

    /// Cmd+D. Pins the selected tab or split, or unpins a pinned/favorite site or split back to tabs.
    func togglePinSelected() {
        guard let id = selectedItemID, let item = library.item(id) else { return }
        guard item.isSplit || item.kind == .site else { return }
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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, library.item(itemID) != nil else { return }
        library.updateItem(itemID) { $0.title = trimmed }
        tabs[itemID]?.replaceTitle(trimmed)
    }

    func toggleExpanded(_ folderID: UUID) {
        guard let item = library.item(folderID), item.kind == .folder else { return }
        withAnimation(SidebarMotion.disclosure) {
            library.updateItem(folderID) { $0.isExpanded.toggle() }
        }
    }

    /// Focuses a folder without unloading the open page. A site goes through `select`.
    func focusSidebarItem(_ id: UUID) {
        guard let item = library.item(id) else { return }
        if item.kind == .site || item.isSplit {
            select(id)
            return
        }
        if item.spaceID != selectedSpaceID {
            adoptSpace(item.spaceID)
        }
        setSidebarFocus(id)
    }

    private func setSidebarFocus(_ id: UUID?) {
        sidebarFocusID = id
        sidebarFocusIsFolder = id.flatMap { library.item($0)?.isFolder } ?? false
    }

    /// Moves an item, and a folder's subtree with it.
    /// A live tab that changes space is unloaded so the next load uses the destination profile.
    /// Its URL is kept on the item. Selection in the space it left moves to a neighbour.
    func moveItem(
        _ id: UUID,
        toSpace spaceID: UUID,
        section: SidebarItem.Section,
        parentID: UUID? = nil,
        position: LibraryStore.Position = .end
    ) {
        guard let root = library.item(id) else { return }
        guard library.canDrop(id, toSpace: spaceID, section: section, parentID: parentID) else { return }

        let origin = root.spaceID
        let follows = root.isFolder || root.isSplit
        let movingIDs = [id] + (follows ? library.descendantIDs(of: id, spaceID: origin) : [])
        let movedSites = Set(movingIDs.filter { library.item($0)?.kind == .site })
        let spaceChanges = origin != spaceID
        let order = navigableItems(in: origin)
        let selected = session.selectedItemBySpace[origin]
        let sourceSplit = library.splitContainer(of: id)?.id
        let previousMembers = sourceSplit.map { library.splitMembers(of: $0).map(\.id) } ?? []
        let wasFocused = sourceSplit.map { resolvedFocus(in: $0) == id } ?? false
        let splitWasSelected = sourceSplit.map { session.selectedItemBySpace[origin] == $0 } ?? false
        let pinsOpenPage = (root.kind == .site || root.isSplit) && root.section == .tabs && section != .tabs

        if spaceChanges || pinsOpenPage {
            for siteID in movedSites {
                guard let site = library.item(siteID) else { continue }
                // A pin's home URL survives a space change. Only an unpinned tab stores the live page.
                let adoptsLiveURL = PinnedPage.recordsLiveURL(in: site.section)
                guard adoptsLiveURL, let live = tabs[siteID]?.url, site.url != live else { continue }
                library.updateItem(siteID) { $0.url = live }
            }
        }

        library.move(id, toSpace: spaceID, section: section, parentID: parentID, position: position)

        if spaceChanges {
            for siteID in movedSites {
                session.interactionStates[siteID] = nil
                unloadTab(siteID)
            }
            if let selected, movingIDs.contains(selected) {
                let anchor = navigableAnchor(for: selected) ?? selected
                let replacement = nextSelection(afterRemoving: movedSites, selected: anchor, order: order)
                if origin == selectedSpaceID {
                    if let replacement {
                        select(replacement)
                    } else {
                        session.selectedItemBySpace[origin] = nil
                        if sidebarFocusID == id || sidebarFocusID.map(movedSites.contains) == true {
                            setSidebarFocus(nil)
                        }
                        refreshNavigationState()
                        syncPictureInPictureForeground()
                    }
                } else {
                    session.selectedItemBySpace[origin] = replacement
                }
            }
        }

        if let sourceSplit, library.splitContainer(of: id)?.id != sourceSplit {
            repairSplit(
                splitID: sourceSplit,
                detachedID: id,
                previousMemberIDs: previousMembers,
                selectDetached: splitWasSelected && wasFocused
            )
        }

        if let focus = sidebarFocusID, library.item(focus)?.spaceID != selectedSpaceID {
            setSidebarFocus(nil)
        }
    }

    /// A link dropped from a page or another app. Tabs opened in the current space are selected.
    func insertDroppedURL(
        _ url: URL,
        toSpace spaceID: UUID,
        section: SidebarItem.Section,
        parentID: UUID? = nil,
        position: LibraryStore.Position = .end
    ) {
        guard library.space(spaceID) != nil else { return }
        let resolvedParent: UUID?
        if section == .pinned,
           let parentID,
           let parent = library.item(parentID),
           parent.isFolder,
           parent.spaceID == spaceID,
           parent.section == .pinned {
            resolvedParent = parentID
        } else {
            resolvedParent = nil
        }
        let title = SidebarTitle.host(of: url) ?? "New Tab"
        let item = library.addItem(
            spaceID: spaceID,
            section: section,
            kind: .site,
            parentID: section == .pinned ? resolvedParent : nil,
            title: title,
            url: url,
            at: position
        )
        guard spaceID == selectedSpaceID, item.section == .tabs else { return }
        select(item.id)
    }

    // MARK: Sidebar / command bar

    func toggleSidebar() { session.isSidebarVisible.toggle() }
    func showCommandBar(_ mode: CommandBarMode) { commandBarMode = mode }

    /// Opens the bar and replaces its query, including when it was already in `mode`.
    func presentCommandBar(_ mode: CommandBarMode) {
        commandBarGeneration += 1
        commandBarMode = mode
    }

    func hideCommandBar() { commandBarMode = nil }

    /// Copies the selected tab's real URL. No-op when there is nothing to copy.
    func copyCurrentLink() {
        guard let url = selectedTab?.url, BrowserTab.isPageURL(url) else { return }
        SidebarClipboard.copy(url)
        linkCopyGeneration &+= 1
    }

    /// window.open / target=_blank, and an extension page opened as a tab.
    /// The new web view uses `configuration` with the 60fps page cap off and is inserted at the top of `.tabs`.
    /// An extension URL is loaded here. A normal page URL is left for WebKit, which navigates the view it asked for.
    @discardableResult
    func presentPopup(configuration: WKWebViewConfiguration, url: URL?, spaceID: UUID, selectTab: Bool = true) -> WKWebView? {
        guard library.space(spaceID) != nil else { return nil }
        let profileID = library.space(spaceID)?.profileID ?? spaceID
        configuration.upgradeKnownHostsToHTTPS = false
        configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        PictureInPictureWebKit.enable(configuration.preferences)
        PageRenderingRate.apply(to: configuration.preferences)
        profiles.prepareConfiguration?(configuration, profileID)
        let pageURL = url.flatMap { BrowserTab.isPageURL($0) ? $0 : nil }
        let extensionURL = url.flatMap { BrowserTab.isExtensionPageURL($0) ? $0 : nil }
        let storedURL = pageURL ?? extensionURL
        let title = storedURL.map { Self.fallbackTitle(for: $0) } ?? "New Tab"
        let item = library.addItem(
            spaceID: spaceID,
            section: .tabs,
            kind: .site,
            title: title,
            url: storedURL,
            at: .start
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let tab = BrowserTab(id: item.id, profileID: profileID, title: title, url: storedURL, adopting: webView)
        wire(tab, spaceID: spaceID)
        tabs[item.id] = tab
        extensions?.tabOpened(tab)
        if let extensionURL {
            webView.load(URLRequest(url: extensionURL))
        }
        guard selectTab else { return tab.webView }
        if selectedSpaceID != spaceID {
            adoptSpace(spaceID)
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
        let focus = session.focusedPaneBySplit.filter { splitID, paneID in
            guard library.item(splitID)?.isSplit == true else { return false }
            return library.splitMembers(of: splitID).contains { $0.id == paneID }
        }
        if focus != session.focusedPaneBySplit {
            session.focusedPaneBySplit = focus
        }
        library.flush()
        session.flush()
        downloads.flush()
    }

    /// A finished PDF, image, text, video, or audio file opens in a new tab. Other types open outside.
    func openDownload(_ id: UUID, inDefaultApp: Bool = false) {
        guard let record = downloads.record(id), downloads.existingFile(id) != nil else { return }
        let inBrowser = !inDefaultApp
            && record.state == .finished
            && DownloadKind.opensInBrowser(filename: record.filename, mimeType: record.mimeType)
        guard inBrowser, let url = downloads.existingFile(id) else {
            if let url = downloads.existingFile(id) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        downloads.isPopoverPresented = false
        downloads.isPagePresented = false
        openInNewTab(url)
    }

    func toggleDownloadsPage() {
        downloads.isPagePresented.toggle()
    }

    func webViewForDownloads(_ profileID: UUID) -> WKWebView? {
        if let tab = tabs.values.first(where: { $0.profileID == profileID && $0.webView != nil }) {
            return tab.webView
        }
        return downloads.auxiliaryWebView(profileID: profileID, configuration: profiles.configuration(for: profileID))
    }

    // MARK: Private

    private func openInNewTab(_ url: URL, spaceID: UUID, inBackground: Bool, httpsFirst: Bool = false) {
        guard library.space(spaceID) != nil else { return }
        let item = library.addItem(
            spaceID: spaceID,
            section: .tabs,
            kind: .site,
            title: Self.fallbackTitle(for: url),
            url: url,
            at: .start
        )
        if httpsFirst {
            ensureTab(for: item).wantsHTTPSFirst = true
        }
        session.lastActiveAt[item.id] = .now
        guard !inBackground else { return }
        if selectedSpaceID != spaceID {
            adoptSpace(spaceID)
        }
        select(item.id)
    }

    func ensureTab(for item: SidebarItem) -> BrowserTab {
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
        tab.downloads = downloads
        tab.useCachedFavicon()
        tab.onOpenInNewTab = { [weak self] url, inBackground in
            self?.openInNewTab(url, spaceID: spaceID, inBackground: inBackground)
        }
        tab.onCreateWebView = { [weak self] configuration, url in
            self?.presentPopup(configuration: configuration, url: url, spaceID: spaceID)
        }
        tab.onStateChange = { [weak self] tab in
            self?.mirror(tab)
            self?.extensions?.tabPropertiesChanged(tab)
        }
        connectExtension(tab, spaceID: spaceID)
        tab.onNavigationChange = { [weak self] tab in
            guard tab.id == self?.selectedTab?.id else { return }
            self?.refreshNavigationState()
        }
        tab.onPictureInPicture = { [weak self] tab in
            self?.ingestPictureInPicture(tab)
        }
        tab.pictureInPictureHost = { [weak self] in
            self?.pictureInPictureContainer()
        }
    }

    func refreshNavigationState() {
        let tab = selectedTab
        let back = tab?.canGoBack == true
        let forward = tab?.canGoForward == true
        let reload = tab != nil
        let pip = tab?.showsPictureInPictureButton == true
        let pipActive = tab?.isPictureInPictureActive == true
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
        if canReload != reload { canReload = reload }
        if canPictureInPicture != pip { canPictureInPicture = pip }
        if pictureInPictureActive != pipActive { pictureInPictureActive = pipActive }
        NavigationCommands.apply(self)
    }

    /// Tabs mirror the live URL and title. Pinned and favorite items keep the URL and title the user saved.
    private func mirror(_ tab: BrowserTab) {
        guard let item = library.item(tab.id), PinnedPage.recordsLiveURL(in: item.section) else { return }
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
        endPictureInPicture(for: id)
        if let tab = tabs[id] {
            extensions?.tabClosed(tab)
            tab.unload()
        }
        tabs[id] = nil
    }

    private func unloadTabs(in spaceID: UUID) {
        let ids = library.items.values.filter { $0.spaceID == spaceID }.map(\.id)
        for id in ids {
            unloadTab(id)
            session.interactionStates[id] = nil
        }
    }

    func navigableItems(in spaceID: UUID) -> [SidebarItem] {
        guard library.space(spaceID) != nil else { return [] }
        var items: [SidebarItem] = []
        items.append(contentsOf: library.children(of: nil, section: .favorites, in: spaceID).filter { $0.kind == .site })
        var visited: Set<UUID> = []
        items.append(contentsOf: pinnedSites(in: spaceID, parentID: nil, visited: &visited))
        items.append(contentsOf: tabPanes(in: spaceID))
        return items
    }

    /// Root tabs, with each split replaced by its panes. The container is not a stop.
    private func tabPanes(in spaceID: UUID) -> [SidebarItem] {
        library.children(of: nil, section: .tabs, in: spaceID).flatMap { child -> [SidebarItem] in
            if child.isSplit {
                return library.splitMembers(of: child.id)
            }
            return child.kind == .site ? [child] : []
        }
    }

    private func pinnedSites(in spaceID: UUID, parentID: UUID?, visited: inout Set<UUID>) -> [SidebarItem] {
        var result: [SidebarItem] = []
        for child in library.children(of: parentID, section: .pinned, in: spaceID) {
            guard visited.insert(child.id).inserted else { continue }
            switch child.kind {
            case .site:
                result.append(child)
            case .split:
                result.append(contentsOf: library.splitMembers(of: child.id))
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
        let currentID = navigableAnchor(for: selectedItemID) ?? selectedItemID
        let current = items.firstIndex { $0.id == currentID }
        let next: Int
        if let current {
            next = (current + delta + items.count) % items.count
        } else {
            next = delta > 0 ? 0 : items.count - 1
        }
        select(items[next].id)
    }

    /// Set while `moveSpace` applies a step, so `adoptSpace` does not replace the command direction with index order.
    private var lockSwitchDirection = false

    private func adoptSpace(_ id: UUID) {
        if !lockSwitchDirection, id != selectedSpaceID {
            lastSpaceSwitchDirection = inferredDirection(from: selectedSpaceID, to: id)
        }
        if selectedSpaceID != id { selectedSpaceID = id }
        if session.selectedSpaceID != id { session.selectedSpaceID = id }
        downloads.visibleProfileID = library.space(id)?.profileID ?? id
    }

    private func inferredDirection(from oldID: UUID, to newID: UUID) -> SpaceSwitchDirection {
        let spaces = library.orderedSpaces
        let oldIndex = spaces.firstIndex { $0.id == oldID } ?? 0
        let newIndex = spaces.firstIndex { $0.id == newID } ?? oldIndex
        return newIndex >= oldIndex ? .next : .previous
    }

    private func moveSpace(by delta: Int) {
        let spaces = library.orderedSpaces
        guard !spaces.isEmpty else { return }
        let index = spaces.firstIndex { $0.id == selectedSpaceID } ?? 0
        let next = (index + delta + spaces.count) % spaces.count
        guard next != index else { return }
        lastSpaceSwitchDirection = delta < 0 ? .previous : .next
        lockSwitchDirection = true
        defer { lockSwitchDirection = false }
        selectSpace(spaces[next].id)
    }

    static func fallbackTitle(for url: URL) -> String {
        if url.isFileURL {
            let name = url.lastPathComponent
            return name.isEmpty ? "File" : name
        }
        if let host = url.host(), !host.isEmpty { return host }
        let absolute = url.absoluteString
        return absolute.isEmpty ? "New Tab" : absolute
    }
}
