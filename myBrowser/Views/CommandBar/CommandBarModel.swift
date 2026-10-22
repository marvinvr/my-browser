import Foundation
import Observation

/// Query, ranked results and selection for the command bar.
/// The view owns one instance per presentation; actions go through `BrowserModel`.
@Observable
final class CommandBarModel {
    enum Row: Identifiable, Equatable {
        case open(title: String, url: URL)
        case search(title: String, url: URL)
        /// A favorite, pin or tab in the current space.
        case tab(SidebarItem)

        var id: String {
            switch self {
            case .open: "open"
            case .search: "search"
            case .tab(let item): "tab-\(item.id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .open(let title, _), .search(let title, _): title
            case .tab(let item): item.title
            }
        }

        var url: URL? {
            switch self {
            case .open(_, let url), .search(_, let url): url
            case .tab(let item): item.url
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
        execute(rows[selection])
    }

    func execute(_ row: Row) {
        switch row {
        case .open(_, let url), .search(_, let url):
            switch mode {
            case .newTab: browser.openInNewTab(url)
            case .editCurrent: browser.openInCurrentTab(url)
            }
        case .tab(let item):
            browser.select(item.id)
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
                next.append(.open(title: "Open \(url.absoluteString)", url: url))
            case .search(let text):
                let url = engine.searchURL(for: text)
                next.append(.search(title: "Search \(engine.displayName) for '\(text)'", url: url))
            }
            let matches = Self.rankedMatches(query: trimmed, items: candidateSites())
            let room = max(0, Self.maxVisibleRows - next.count)
            next.append(contentsOf: matches.prefix(room).map { .tab($0) })
        }
        rows = next
        if resetSelection || !rows.indices.contains(selection) {
            selection = 0
        }
    }

    private func candidateSites() -> [SidebarItem] {
        let spaceID = browser.selectedSpaceID
        return browser.library.items.values.filter { item in
            item.deletedAt == nil && item.spaceID == spaceID && item.kind == .site
        }
    }

    private func openTabs() -> [SidebarItem] {
        candidateSites()
            .filter { $0.section == .tabs }
            .sorted { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
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
