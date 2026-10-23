import Foundation
import Testing
@testable import myBrowser

@MainActor
struct CommandBarModelTests {
    @Test func primaryActionOpensAURLOrSearches() {
        let browser = makeBrowser()
        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .duckDuckGo)

        bar.query = "example.com/path?q=1"
        #expect(bar.rows.first == .open(title: "Open https://example.com/path?q=1", url: URL(string: "https://example.com/path?q=1")!, httpsFirst: true))

        bar.query = "cats & dogs"
        let searchURL = SearchEngine.duckDuckGo.searchURL(for: "cats & dogs")
        #expect(bar.rows.first == .search(title: "Search DuckDuckGo for 'cats & dogs'", url: searchURL))

        let editing = CommandBarModel(browser: browser, mode: .editCurrent, engine: .google)
        editing.query = "example.com"
        guard case .open(_, let url, let httpsFirst) = editing.rows.first else {
            Issue.record("expected an open row")
            return
        }
        #expect(url.absoluteString == "https://example.com")
        #expect(httpsFirst)
        #expect(editing.mode == .editCurrent)
    }

    @Test func ranksHostPrefixAboveTitleAboveURL() {
        let browser = makeBrowser()
        let space = browser.selectedSpaceID
        browser.library.addItem(spaceID: space, section: .tabs, title: "Notes", url: URL(string: "https://example.com/git")!)
        browser.library.addItem(spaceID: space, section: .pinned, title: "Git Guide", url: URL(string: "https://example.com/notes")!)
        browser.library.addItem(
            spaceID: space,
            section: .favorites,
            title: "Code",
            url: URL(string: "https://www.github.com/a")!
        )
        browser.library.addItem(spaceID: space, section: .pinned, kind: .folder, title: "git folder")
        browser.library.addItem(spaceID: space, section: .tabs, title: "News", url: URL(string: "https://nytimes.com")!)
        let dead = browser.library.addItem(spaceID: space, section: .pinned, title: "git dead", url: URL(string: "https://example.com/dead")!)
        browser.library.deleteItem(dead.id)
        let other = browser.library.createSpace(name: "Other")
        browser.library.addItem(spaceID: other.id, section: .tabs, title: "git elsewhere", url: URL(string: "https://github.com/other")!)

        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        bar.query = "git"
        #expect(rowTitles(bar) == [
            "Search Google for 'git'",
            "Code",
            "Git Guide",
            "Notes"
        ])

        bar.query = "GIT"
        #expect(Array(rowTitles(bar).dropFirst()) == ["Code", "Git Guide", "Notes"])

        bar.query = "hub"
        #expect(Array(rowTitles(bar).dropFirst()) == ["Code"])
    }

    @Test func staticRankingOrdersSectionsOnATie() {
        let space = UUID()
        let items = [
            site(space: space, section: .tabs, title: "GitLab", url: "https://gitlab.com", sort: "b"),
            site(space: space, section: .favorites, title: "GitHub", url: "https://github.com", sort: "a"),
            site(space: space, section: .pinned, title: "Gitea", url: "https://gitea.io", sort: "c"),
        ]
        let ranked = CommandBarModel.rankedMatches(query: "git", items: items)
        #expect(ranked.map(\.title) == ["GitHub", "Gitea", "GitLab"])
        #expect(CommandBarModel.matchRank(item: items[1], query: "git") == 0)
        #expect(CommandBarModel.matchRank(item: site(space: space, section: .tabs, title: "Git Notes", url: "https://example.com", sort: "d"), query: "git") == 1)
        #expect(CommandBarModel.matchRank(item: site(space: space, section: .tabs, title: "Readme", url: "https://example.com/git", sort: "e"), query: "git") == 2)
    }

    @Test func emptyNewTabQueryListsOpenTabsOnly() {
        let browser = makeBrowser()
        let space = browser.selectedSpaceID
        browser.library.addItem(spaceID: space, section: .favorites, title: "Fav", url: URL(string: "https://example.com")!)
        browser.library.addItem(spaceID: space, section: .tabs, title: "One", url: URL(string: "https://one.example")!)
        browser.library.addItem(spaceID: space, section: .tabs, title: "Two", url: URL(string: "https://two.example")!)
        browser.library.addItem(spaceID: space, section: .pinned, title: "Pin", url: URL(string: "https://pin.example")!)

        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        #expect(rowTitles(bar) == ["One", "Two"])

        let editing = CommandBarModel(browser: browser, mode: .editCurrent, engine: .google)
        #expect(editing.rows.isEmpty)
    }

    @Test func capsTheListAtEightRows() {
        let browser = makeBrowser()
        let space = browser.selectedSpaceID
        for index in 0..<12 {
            browser.library.addItem(
                spaceID: space,
                section: .tabs,
                title: "Alpha \(index)",
                url: URL(string: "https://example.com/\(index)")!
            )
        }
        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        #expect(bar.rows.count == 8)
        bar.query = "alpha"
        #expect(bar.rows.count == CommandBarModel.maxVisibleRows)
        guard case .search = bar.rows[0] else {
            Issue.record("expected a search primary action")
            return
        }
        #expect(bar.rows.dropFirst().count == 7)
    }

    @Test func selectionMovesClampsAndResetsWithTheQuery() {
        let browser = makeBrowser()
        let space = browser.selectedSpaceID
        browser.library.addItem(spaceID: space, section: .tabs, title: "Git Notes", url: URL(string: "https://example.com/git")!)
        browser.library.addItem(spaceID: space, section: .tabs, title: "Other", url: URL(string: "https://nytimes.com")!)
        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        bar.query = "git"
        #expect(bar.rows.count >= 2)
        #expect(bar.selection == 0)
        bar.moveSelection(1)
        #expect(bar.selection == 1)
        bar.moveSelection(50)
        #expect(bar.selection == bar.rows.count - 1)
        bar.moveSelection(-50)
        #expect(bar.selection == 0)
        bar.moveSelection(1)
        bar.query = "github.com"
        #expect(bar.selection == 0)
    }

    @Test func executeHidesTheCommandBar() {
        let browser = makeBrowser()
        browser.showCommandBar(.newTab)
        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        bar.query = "example.com"
        bar.execute()
        #expect(browser.commandBarMode == nil)

        browser.showCommandBar(.editCurrent)
        let editing = CommandBarModel(browser: browser, mode: .editCurrent, engine: .google)
        editing.query = "example.com"
        editing.execute()
        #expect(browser.commandBarMode == nil)
    }

    @Test func splitQueryOffersTheActionWhenATabCanSplit() {
        let browser = makeBrowser()
        let space = browser.selectedSpaceID
        let page = browser.library.addItem(
            spaceID: space,
            section: .tabs,
            title: "Notes",
            url: URL(string: "https://example.com/notes")!
        )
        browser.select(page.id)
        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        bar.query = "split"
        #expect(bar.rows.map(\.title).contains("Open in Split View"))
        let index = bar.rows.firstIndex { $0.title == "Open in Split View" } ?? 0
        bar.moveSelection(index)
        bar.execute()
        #expect(browser.commandBarMode == .editCurrent)
        #expect(browser.library.item(browser.selectedItemID ?? UUID())?.isSplit == true)
        let unrelated = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        unrelated.query = "git"
        #expect(unrelated.rows.map(\.title) == ["Search Google for 'git'"])
    }

    @Test func quickSwitchEnterHidesTheBar() {
        let browser = makeBrowser()
        let space = browser.selectedSpaceID
        browser.library.addItem(spaceID: space, section: .tabs, title: "One", url: URL(string: "https://one.example")!)
        browser.showCommandBar(.newTab)
        let bar = CommandBarModel(browser: browser, mode: .newTab, engine: .google)
        #expect(bar.rows.count == 1)
        bar.execute()
        #expect(browser.commandBarMode == nil)
    }

    private func rowTitles(_ bar: CommandBarModel) -> [String] {
        bar.rows.map(\.title)
    }

    private func makeBrowser() -> BrowserModel {
        BrowserModel(library: LibraryStore(directory: nil), session: SessionStore(directory: nil))
    }

    private func site(space: UUID, section: SidebarItem.Section, title: String, url: String, sort: String) -> SidebarItem {
        SidebarItem(spaceID: space, section: section, kind: .site, title: title, url: URL(string: url)!, sortKey: sort)
    }
}
