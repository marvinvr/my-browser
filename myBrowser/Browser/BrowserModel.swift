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
    var selectedTab: BrowserTab? { selectedItemID.flatMap { tabs[$0] } }
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

    /// Sites in sidebar order for the current space: favorites, pinned (depth-first, expanded folders only), tabs.
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
    func select(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site else { return }
        // The tab being left was viewed until this moment, so its idle time starts now.
        if let previous = session.selectedItemBySpace[item.spaceID], previous != itemID {
            session.lastActiveAt[previous] = .now
        }
        session.lastActiveAt[itemID] = .now
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

    /// Opens `url` in a new `.tabs` item at the top of the current space. Background leaves the selection alone.
    /// `httpsFirst` may fall back to HTTP once if that load fails.
    func openInNewTab(_ url: URL, inBackground: Bool = false, httpsFirst: Bool = false) {
        guard let spaceID = selectedSpace?.id else { return }
        openInNewTab(url, spaceID: spaceID, inBackground: inBackground, httpsFirst: httpsFirst)
    }

    /// Loads `url` in the selected tab, or a new tab when nothing is selected.
    func openInCurrentTab(_ url: URL, httpsFirst: Bool = false) {
        if let id = selectedItemID, library.item(id)?.kind == .site {
            select(id)
            tabs[id]?.load(url, httpsFirst: httpsFirst)
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
    func close(_ itemID: UUID, archivingAt: Date?) {
        guard let item = library.item(itemID), item.kind == .site else { return }
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
            session.lastActiveAt[id] = nil
            unloadTab(id)
        }
        if sidebarFocusID == itemID || sidebarFocusID.map(removed.contains) == true {
            setSidebarFocus(nil)
        }
        library.deleteItem(itemID)

        guard let selected, removed.contains(selected) else { return }
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

    /// Moves a `.tabs` item to the end of `.pinned`. The URL stays the page that's open.
    func pin(_ itemID: UUID) {
        guard let item = library.item(itemID), item.section == .tabs, item.kind == .site else { return }
        let url = tabs[itemID]?.url ?? item.url
        library.moveItem(itemID, to: .pinned, parentID: nil, at: .end)
        if let url, library.item(itemID)?.url != url {
            library.updateItem(itemID) { $0.url = url }
        }
        if let tab = tabs[itemID] { extensions?.tabPropertiesChanged(tab) }
    }

    /// Moves a pinned or favorite site to the top of `.tabs`.
    func unpin(_ itemID: UUID) {
        guard let item = library.item(itemID), item.kind == .site, item.section != .tabs else { return }
        library.moveItem(itemID, to: .tabs, parentID: nil, at: .start)
        if let tab = tabs[itemID] { extensions?.tabPropertiesChanged(tab) }
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
        if item.kind == .site {
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
        let movingIDs = [id] + (root.isFolder ? library.descendantIDs(of: id, spaceID: origin) : [])
        let movedSites = Set(movingIDs.filter { library.item($0)?.kind == .site })
        let spaceChanges = origin != spaceID
        let order = navigableItems(in: origin)
        let selected = session.selectedItemBySpace[origin]
        let pinsOpenPage = root.kind == .site && root.section == .tabs && section != .tabs

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
            if let selected, movedSites.contains(selected) {
                let replacement = nextSelection(afterRemoving: movedSites, selected: selected, order: order)
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
        configuration.upgradeKnownHostsToHTTPS = false
        configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        PictureInPictureWebKit.enable(configuration.preferences)
        PageRenderingRate.apply(to: configuration.preferences)
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
        let profileID = library.space(spaceID)?.profileID ?? spaceID
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
            guard tab.id == self?.selectedItemID else { return }
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
