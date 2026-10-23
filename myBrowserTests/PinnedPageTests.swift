import Foundation
import Testing
@testable import myBrowser

struct PinnedPageTests {
    private let home = URL(string: "https://example.com/notes")!
    private let homeSlash = URL(string: "https://example.com/notes/")!
    private let homeFragment = URL(string: "https://example.com/notes#section")!
    private let homeBoth = URL(string: "https://Example.com/notes/#section")!
    private let away = URL(string: "https://example.com/notes/other")!
    private let query = URL(string: "https://example.com/notes?q=1")!
    private let queryFragment = URL(string: "https://example.com/notes?q=1#x")!
    private let root = URL(string: "https://example.com")!
    private let rootSlash = URL(string: "https://example.com/")!
    private let rootFragment = URL(string: "https://example.com/#top")!

    @Test func sameURLIsHome() {
        #expect(PinnedPage.isAway(current: home, saved: home) == false)
    }

    @Test func fragmentAndTrailingSlashAreTheSamePage() {
        #expect(PinnedPage.canonical(home) == PinnedPage.canonical(homeSlash))
        #expect(PinnedPage.canonical(home) == PinnedPage.canonical(homeFragment))
        #expect(PinnedPage.canonical(home) == PinnedPage.canonical(homeBoth))
        #expect(PinnedPage.isAway(current: homeSlash, saved: home) == false)
        #expect(PinnedPage.isAway(current: homeFragment, saved: home) == false)
        #expect(PinnedPage.isAway(current: homeBoth, saved: homeSlash) == false)
    }

    @Test func rootSlashAndFragmentAreTheSamePage() {
        #expect(PinnedPage.canonical(root) == PinnedPage.canonical(rootSlash))
        #expect(PinnedPage.canonical(root) == PinnedPage.canonical(rootFragment))
        #expect(PinnedPage.isAway(current: rootSlash, saved: root) == false)
    }

    @Test func extraTrailingSlashesCollapse() {
        let many = URL(string: "https://example.com/notes///")!
        #expect(PinnedPage.canonical(many) == PinnedPage.canonical(home))
        let rootMany = URL(string: "https://example.com///")!
        #expect(PinnedPage.canonical(rootMany) == PinnedPage.canonical(root))
    }

    @Test func pathAndQueryDifferencesAreAway() {
        #expect(PinnedPage.isAway(current: away, saved: home))
        #expect(PinnedPage.isAway(current: query, saved: home))
        #expect(PinnedPage.isAway(current: queryFragment, saved: query) == false)
        #expect(PinnedPage.isAway(current: URL(string: "http://example.com/notes"), saved: home))
    }

    @Test func missingURLs() {
        #expect(PinnedPage.isAway(current: nil, saved: home) == false)
        #expect(PinnedPage.isAway(current: home, saved: nil))
        #expect(PinnedPage.isAway(current: nil, saved: nil) == false)
        #expect(PinnedPage.isAway(current: URL(string: "about:blank"), saved: home) == false)
    }

    @Test func onlyTabsRecordTheLiveURL() {
        #expect(PinnedPage.recordsLiveURL(in: .tabs))
        #expect(PinnedPage.recordsLiveURL(in: .pinned) == false)
        #expect(PinnedPage.recordsLiveURL(in: .favorites) == false)
    }

    @Test func navigationLeavesTheSavedURL() {
        let start = pin(loaded: true)
        let next = PinnedPage.navigate(start, to: away, title: "Other")
        #expect(next.savedURL == home)
        #expect(next.savedTitle == "Notes")
        #expect(next.currentURL == away)
        #expect(next.currentTitle == "Other")
        #expect(next.hasInteractionState == start.hasInteractionState)
        #expect(PinnedPage.isAway(current: next.currentURL, saved: next.savedURL))
    }

    @Test func navigationIgnoresABlankTitleAndAnUnloadedPin() {
        let start = pin(loaded: true)
        let blank = PinnedPage.navigate(start, to: away, title: "   ")
        #expect(blank.currentURL == away)
        #expect(blank.currentTitle == "Notes")
        #expect(blank.savedURL == home)

        var closed = start
        closed.loaded = false
        let ignored = PinnedPage.navigate(closed, to: away, title: "Other")
        #expect(ignored == closed)
    }

    @Test func closeDropsTheLivePageAndKeepsTheHomeURL() {
        var awayState = PinnedPage.navigate(pin(loaded: true), to: away, title: "Other")
        awayState.hasInteractionState = true
        let closed = PinnedPage.close(awayState)
        #expect(closed.savedURL == home)
        #expect(closed.savedTitle == "Notes")
        #expect(closed.loaded == false)
        #expect(closed.currentURL == nil)
        #expect(closed.hasInteractionState == false)

        let opened = PinnedPage.open(closed)
        #expect(opened.loaded)
        #expect(opened.currentURL == home)
        #expect(opened.currentTitle == "Notes")
        #expect(opened.hasInteractionState == false)
        #expect(PinnedPage.isAway(current: opened.currentURL, saved: opened.savedURL) == false)
    }

    @Test func replaceWritesTheLivePageAndReturnHomeLoadsTheSavedURL() {
        let awayState = PinnedPage.navigate(pin(loaded: true), to: away, title: "Other page")
        let replaced = PinnedPage.replaceWithCurrent(awayState)
        #expect(replaced.savedURL == away)
        #expect(replaced.savedTitle == "Other page")
        #expect(PinnedPage.isAway(current: replaced.currentURL, saved: replaced.savedURL) == false)

        let homeAgain = PinnedPage.replaceWithCurrent(pin(loaded: true))
        #expect(homeAgain.savedURL == home)
        #expect(homeAgain.savedTitle == "Notes")

        var untitled = awayState
        untitled.currentTitle = "  "
        #expect(PinnedPage.replaceWithCurrent(untitled).savedTitle == "example.com")

        let returned = PinnedPage.returnHome(awayState)
        #expect(returned.savedURL == home)
        #expect(returned.currentURL == home)
        #expect(returned.currentTitle == "Notes")
        #expect(returned.hasInteractionState == false)
        #expect(PinnedPage.returnHome(pin(loaded: true)) == pin(loaded: true))
    }

    private func pin(loaded: Bool) -> PinnedPage.State {
        PinnedPage.State(
            savedURL: home,
            savedTitle: "Notes",
            currentURL: loaded ? home : nil,
            currentTitle: loaded ? "Notes" : "",
            loaded: loaded,
            hasInteractionState: false
        )
    }
}
