import Foundation
import Observation

/// Query, ranked results and selection for the command bar.
/// The view owns one instance per presentation; actions go through `BrowserModel`.
@Observable
final class CommandBarModel {
    /// Split commands offered when the query names them. The bar has no separate action catalog.
    enum Action: String, CaseIterable, Identifiable {
        case openInSplit
        case separatePane
        case separateAll
        case swapPanes
        case focusNext
        case focusPrevious

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openInSplit: "Open in Split View"
            case .separatePane: "Separate Pane"
            case .separateAll: "Separate All"
            case .swapPanes: "Swap Panes"
            case .focusNext: "Focus Next Pane"
            case .focusPrevious: "Focus Previous Pane"
            }
        }

        var symbol: String {
            switch self {
            case .openInSplit: "rectangle.split.2x1"
            case .separatePane: "rectangle.split.2x1"
            case .separateAll: "square.split.2x1"
            case .swapPanes: "arrow.left.arrow.right"
            case .focusNext: "arrow.right"
            case .focusPrevious: "arrow.left"
            }
        }

        fileprivate var keywords: [String] {
            switch self {
            case .openInSplit: ["split", "open in split", "split view"]
            case .separatePane: ["separate", "separate pane"]
            case .separateAll: ["separate all", "dissolve"]
            case .swapPanes: ["swap", "swap panes"]
            case .focusNext: ["focus next", "next pane"]
            case .focusPrevious: ["focus previous", "previous pane"]
            }
        }
    }

    enum Row: Identifiable, Equatable {
        case open(title: String, url: URL, httpsFirst: Bool)
        case search(title: String, url: URL)
        /// A favorite, pin or tab in the current space.
        case tab(SidebarItem)
        case action(Action)
        /// Opens the Archived Tabs list.
        case archivedTabs

        var id: String {
            switch self {
            case .open: "open"
            case .search: "search"
            case .tab(let item): "tab-\(item.id.uuidString)"
            case .action(let action): "action-\(action.rawValue)"
            case .archivedTabs: "archived-tabs"
            }
        }

        var title: String {
            switch self {
            case .open(let title, _, _), .search(let title, _): title
            case .tab(let item): item.title
            case .action(let action): action.title
            case .archivedTabs: "Archived Tabs"
            }
        }

        var url: URL? {
            switch self {
            case .open(_, let url, _), .search(_, let url): url
            case .tab(let item): item.url
            case .action, .archivedTabs: nil
            }
        }
    }

    /// Primary action plus matches. The list never grows past this.
    static let maxVisibleRows = 8

    let mode: BrowserModel.CommandBarMode
    let engine: SearchEngine

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild(resetSelection: true)
        }
    }

    private(set) var rows: [Row] = []
    private(set) var selection = 0

    private let browser: BrowserModel
    private var lookupTask: Task<Void, Never>?

    init(browser: BrowserModel, mode: BrowserModel.CommandBarMode, engine: SearchEngine = .current) {
        self.browser = browser
        self.mode = mode
        self.engine = engine
        if mode == .editCurrent, let absolute = browser.selectedTab?.url?.absoluteString {
            query = absolute
        }
        rebuild(resetSelection: true)
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(0, selection + delta), rows.count - 1)
    }

    func execute() {
        guard rows.indices.contains(selection) else { return }
        let row = rows[selection]
        // A bare name may still be a search until DNS answers. Enter waits for that answer.
        if selection == 0, case .search = row, let name = URLInput.bareHostCandidate(query) {
            lookupTask?.cancel()
            let typed = query
            Task { @MainActor [weak self] in
                let found = await BareHostLookup.resolves(name)
                guard let self, self.browser.commandBarMode != nil else { return }
                guard URLInput.bareHostCandidate(self.query) == name || self.query == typed else { return }
                if found, case .url(let url) = URLInput.resolve(self.query) {
                    self.commit(url: url, httpsFirst: false)
                    return
                }
                self.execute(row)
            }
            return
        }
        execute(row)
    }

    func execute(_ row: Row) {
        switch row {
        case .open(_, let url, let httpsFirst):
            commit(url: url, httpsFirst: httpsFirst)
        case .search(_, let url):
            commit(url: url, httpsFirst: false)
        case .tab(let item):
            browser.select(item.id)
            browser.hideCommandBar()
        case .action(let action):
            let keepOpen = action == .openInSplit && browser.openInSplitView()
            if !keepOpen { browser.hideCommandBar() }
        case .archivedTabs:
            browser.isPresentingArchive = true
            browser.hideCommandBar()
        }
    }

    private func commit(url: URL, httpsFirst: Bool) {
        switch mode {
        case .newTab: browser.openInNewTab(url, httpsFirst: httpsFirst)
        case .editCurrent: browser.openInCurrentTab(url, httpsFirst: httpsFirst)
        }
        browser.hideCommandBar()
    }

    // MARK: Ranking

    /// Sites in `items` whose title or URL contains `query`, best rank first.
    /// Rank: host prefix, then title contains, then URL contains.
    static func rankedMatches(query: String, items: [SidebarItem]) -> [SidebarItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return items.compactMap { item -> Ranked? in
            guard let rank = matchRank(item: item, query: trimmed) else { return nil }
            return Ranked(item: item, rank: rank)
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let leftSection = sectionIndex(lhs.item.section)
            let rightSection = sectionIndex(rhs.item.section)
            if leftSection != rightSection { return leftSection < rightSection }
            return (lhs.item.sortKey, lhs.item.id.uuidString) < (rhs.item.sortKey, rhs.item.id.uuidString)
        }
        .map(\.item)
    }

    /// 0 host prefix, 1 title, 2 URL. Nil when the site does not match.
    static func matchRank(item: SidebarItem, query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, item.kind == .site, item.deletedAt == nil else { return nil }
        if hostHasPrefix(item.url, query: trimmed) { return 0 }
        if item.title.range(of: trimmed, options: .caseInsensitive) != nil { return 1 }
        if let absolute = item.url?.absoluteString, absolute.range(of: trimmed, options: .caseInsensitive) != nil {
            return 2
        }
        return nil
    }

    // MARK: Private

    private struct Ranked {
        var item: SidebarItem
        var rank: Int
    }

    private func rebuild(resetSelection: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: [Row] = []
        if trimmed.isEmpty {
            if mode == .newTab {
                next = openTabs().prefix(Self.maxVisibleRows).map { .tab($0) }
            }
        } else {
            switch URLInput.resolve(trimmed) {
            case .url(let url):
                next.append(.open(
                    title: "Open \(url.absoluteString)",
                    url: url,
                    httpsFirst: URLInput.isHTTPSFirst(trimmed)
                ))
            case .search(let text):
                let url = engine.searchURL(for: text)
                next.append(.search(title: "Search \(engine.displayName) for '\(text)'", url: url))
            }
            if Self.wantsArchivedTabs(trimmed) {
                next.append(.archivedTabs)
            }
            if case .search = next.first {
                let actions = Self.matchingActions(query: trimmed, browser: browser)
                let actionRoom = max(0, Self.maxVisibleRows - next.count)
                next.append(contentsOf: actions.prefix(actionRoom).map { .action($0) })
            }
            let matches = Self.rankedMatches(query: trimmed, items: candidateSites())
            let room = max(0, Self.maxVisibleRows - next.count)
            next.append(contentsOf: matches.prefix(room).map { .tab($0) })
        }
        rows = next
        if resetSelection || !rows.indices.contains(selection) {
            selection = 0
        }
        if let name = URLInput.bareHostCandidate(trimmed), case .search = next.first {
            scheduleBareHostLookup(name)
        } else {
            lookupTask?.cancel()
        }
    }

    /// Fills the DNS cache, then rebuilds so `photos` becomes Open once it resolves.
    private func scheduleBareHostLookup(_ name: String) {
        lookupTask?.cancel()
        lookupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            let found = await BareHostLookup.resolves(name)
            guard !Task.isCancelled, found else { return }
            var current = self.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while current.hasSuffix(".") { current.removeLast() }
            guard current == name else { return }
            self.rebuild(resetSelection: false)
        }
    }

    private func candidateSites() -> [SidebarItem] {
        let spaceID = browser.selectedSpaceID
        return browser.library.items.values.filter { item in
            item.deletedAt == nil && item.spaceID == spaceID && item.kind == .site
        }
    }

    /// "archive", "archived", "archived tabs", and a prefix of that title ("arch").
    static func wantsArchivedTabs(_ query: String) -> Bool {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard folded.count >= 3 else { return false }
        if folded.contains("archive") { return true }
        return "archived tabs".hasPrefix(folded)
    }

    private func openTabs() -> [SidebarItem] {
        candidateSites()
            .filter { $0.section == .tabs }
            .sorted { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
    }

    /// Actions whose keywords contain the query, and that the current selection can run.
    static func matchingActions(query: String, browser: BrowserModel) -> [Action] {
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard folded.count >= 3 else { return [] }
        return Action.allCases.filter { action in
            guard action.keywords.contains(where: { $0.hasPrefix(folded) || $0.contains(folded) }) else { return false }
            switch action {
            case .openInSplit: return browser.canOpenInSplitView
            case .separatePane, .separateAll, .focusNext, .focusPrevious: return browser.canSeparatePane
            case .swapPanes: return browser.canSwapPanes
            }
        }
    }

    private static func sectionIndex(_ section: SidebarItem.Section) -> Int {
        switch section {
        case .favorites: 0
        case .pinned: 1
        case .tabs: 2
        }
    }

    private static func hostHasPrefix(_ url: URL?, query: String) -> Bool {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return false }
        let folded = query.lowercased()
        if host.hasPrefix(folded) { return true }
        if host.hasPrefix("www.") {
            return host.dropFirst(4).hasPrefix(folded)
        }
        return false
    }
}
