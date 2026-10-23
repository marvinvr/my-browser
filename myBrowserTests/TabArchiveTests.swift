import Foundation
import Testing
@testable import myBrowser

@MainActor
struct TabArchivePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func labelsAndDefaultInterval() {
        #expect(TabArchiveInterval.allCases.map(\.label) == ["12 hours", "24 hours", "7 days", "30 days", "Never"])
        #expect(TabArchiveInterval.resolved(nil) == .twentyFourHours)
        #expect(TabArchiveInterval.resolved("nope") == .twentyFourHours)
        #expect(TabArchiveInterval.resolved("12h") == .twelveHours)
        #expect(TabArchiveInterval.twelveHours.duration == 43_200)
        #expect(TabArchiveInterval.twentyFourHours.duration == 86_400)
        #expect(TabArchiveInterval.sevenDays.duration == 604_800)
        #expect(TabArchiveInterval.thirtyDays.duration == 2_592_000)
        #expect(TabArchiveInterval.never.duration == nil)
    }

    @Test func idleLongerThanTheIntervalIsArchived() {
        let day: TimeInterval = 24 * 60 * 60
        let exact = candidate(age: day)
        let justOver = candidate(age: day + 1)
        let fresh = candidate(age: day - 1)
        #expect(TabArchivePolicy.idsToArchive([exact], interval: day, now: now).isEmpty)
        #expect(TabArchivePolicy.idsToArchive([justOver], interval: day, now: now) == [justOver.id])
        #expect(TabArchivePolicy.idsToArchive([fresh], interval: day, now: now).isEmpty)

        for interval in [TabArchiveInterval.twelveHours, .sevenDays, .thirtyDays] {
            let duration = interval.duration ?? 0
            #expect(duration > 0)
            let onTheLine = candidate(age: duration)
            let past = candidate(age: duration + 1)
            #expect(TabArchivePolicy.idsToArchive([onTheLine], interval: duration, now: now).isEmpty)
            #expect(TabArchivePolicy.idsToArchive([past], interval: duration, now: now) == [past.id])
        }
    }

    @Test func neverAndMissingActivityArchiveNothing() {
        let old = candidate(age: 400 * 24 * 60 * 60)
        #expect(TabArchivePolicy.idsToArchive([old], interval: nil, now: now).isEmpty)
        var unknown = candidate(age: 0)
        unknown.lastActiveAt = nil
        #expect(TabArchivePolicy.idsToArchive([unknown], interval: 60, now: now).isEmpty)
    }

    @Test func exclusionsStayOpen() {
        let duration: TimeInterval = 60
        let stale = candidate(age: 120)
        var pinned = stale
        pinned.section = .pinned
        var favorite = stale
        favorite.section = .favorites
        var folder = stale
        folder.kind = .folder
        var selected = stale
        selected.isSelected = true
        var playing = stale
        playing.isPlayingMedia = true
        var pip = stale
        pip.isPictureInPicture = true
        var download = stale
        download.hasActiveDownload = true

        let ids = TabArchivePolicy.idsToArchive(
            [pinned, favorite, folder, selected, playing, pip, download, stale],
            interval: duration,
            now: now
        )
        #expect(ids == [stale.id])
    }

    @Test func oldestIdleTabIsFirst() {
        let older = candidate(age: 10 * 24 * 60 * 60)
        let newer = candidate(age: 3 * 24 * 60 * 60)
        let ids = TabArchivePolicy.idsToArchive([newer, older], interval: 24 * 60 * 60, now: now)
        #expect(ids == [older.id, newer.id])
    }

    @Test func archiveRetentionIsThirtyDays() {
        let retention = TabArchivePolicy.retention
        let onTheLine = now.addingTimeInterval(-retention)
        let past = now.addingTimeInterval(-retention - 1)
        #expect(!TabArchivePolicy.isExpired(archivedAt: onTheLine, now: now))
        #expect(TabArchivePolicy.isExpired(archivedAt: past, now: now))
    }

    private func candidate(age: TimeInterval) -> TabArchiveCandidate {
        TabArchiveCandidate(
            id: UUID(),
            section: .tabs,
            kind: .site,
            lastActiveAt: now.addingTimeInterval(-age),
            isSelected: false,
            isPlayingMedia: false,
            isPictureInPicture: false,
            hasActiveDownload: false
        )
    }
}

@MainActor
struct TabArchiveModelTests {
    private func makeModel() -> (BrowserModel, LibraryStore, SessionStore) {
        let library = LibraryStore(directory: nil)
        let session = SessionStore(directory: nil)
        return (BrowserModel(library: library, session: session), library, session)
    }

    private func site(
        _ library: LibraryStore,
        spaceID: UUID,
        title: String,
        section: SidebarItem.Section,
        parentID: UUID? = nil
    ) -> SidebarItem {
        library.addItem(
            spaceID: spaceID,
            section: section,
            kind: section == .pinned && parentID != nil ? .site : .site,
            parentID: parentID,
            title: title,
            url: URL(string: "https://\(title.lowercased()).example"),
            at: .end
        )
    }

    @Test func monitorDoesNotRunInsideTheTestHost() {
        #expect(BrowserModel.runsArchiveMonitor == false)
    }

    @Test func archivesStaleUnpinnedTabsAndReopensFromTheStack() throws {
        let (model, library, session) = makeModel()
        let personal = try #require(model.selectedSpace?.id)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 24 * 60 * 60

        let fresh = site(library, spaceID: personal, title: "Fresh", section: .tabs)
        let stale = site(library, spaceID: personal, title: "Stale", section: .tabs)
        let selected = site(library, spaceID: personal, title: "Selected", section: .tabs)
        let pinned = site(library, spaceID: personal, title: "Pinned", section: .pinned)
        let favorite = site(library, spaceID: personal, title: "Favorite", section: .favorites)
        let folder = library.addItem(spaceID: personal, section: .pinned, kind: .folder, title: "Folder", at: .end)
        let nested = site(library, spaceID: personal, title: "Nested", section: .pinned, parentID: folder.id)
        let work = model.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)
        let workTab = site(library, spaceID: work.id, title: "Worktab", section: .tabs)
        let unstamped = site(library, spaceID: personal, title: "Unstamped", section: .tabs)

        session.selectedItemBySpace[personal] = selected.id
        session.selectedItemBySpace[work.id] = workTab.id
        session.interactionStates[stale.id] = Data([9, 9])
        let old = now.addingTimeInterval(-10 * day)
        session.lastActiveAt = [
            fresh.id: now.addingTimeInterval(-2 * 60 * 60),
            stale.id: now.addingTimeInterval(-(day + 90)),
            selected.id: old,
            pinned.id: old,
            favorite.id: old,
            nested.id: old,
            workTab.id: old,
        ]

        model.archiveInactiveTabs(now: now, interval: .twentyFourHours)

        #expect(library.item(stale.id) == nil)
        #expect(session.archivedTabs.map(\.item.title) == ["Stale"])
        #expect(session.archivedTabs.last?.interactionState == Data([9, 9]))
        #expect(session.closedTabs.map(\.item.id) == [stale.id])
        #expect(library.item(fresh.id) != nil)
        #expect(library.item(selected.id) != nil)
        #expect(library.item(pinned.id)?.section == .pinned)
        #expect(library.item(favorite.id)?.section == .favorites)
        #expect(library.item(nested.id)?.parentID == folder.id)
        #expect(library.item(workTab.id) != nil)
        #expect(library.item(unstamped.id) != nil)
        #expect(session.lastActiveAt[unstamped.id] == now)

        model.reopenClosedTab()
        #expect(library.item(stale.id)?.section == .tabs)
        #expect(session.interactionStates[stale.id] == Data([9, 9]))
        #expect(session.archivedTabs.isEmpty)
        #expect(session.closedTabs.isEmpty)
        #expect(model.selectedItemID == stale.id)
    }

    @Test func manualCloseDoesNotArchive() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let keeper = site(library, spaceID: spaceID, title: "Keeper", section: .tabs)
        let closing = site(library, spaceID: spaceID, title: "Closing", section: .tabs)
        session.selectedItemBySpace[spaceID] = closing.id

        model.close(closing.id)

        #expect(library.item(closing.id) == nil)
        #expect(session.archivedTabs.isEmpty)
        #expect(session.closedTabs.map(\.item.id) == [closing.id])
        #expect(model.selectedItemID == keeper.id)
    }

    @Test func shorterIntervalArchivesSoonerAndTheListReopenDropsTheStack() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tab = site(library, spaceID: spaceID, title: "Idle", section: .tabs)
        let keeper = site(library, spaceID: spaceID, title: "Keeper", section: .tabs)
        session.selectedItemBySpace[spaceID] = keeper.id
        session.lastActiveAt[tab.id] = now.addingTimeInterval(-(12 * 60 * 60))
        session.lastActiveAt[keeper.id] = now

        model.archiveInactiveTabs(now: now, interval: .twelveHours)
        #expect(library.item(tab.id) != nil)

        session.lastActiveAt[tab.id] = now.addingTimeInterval(-(12 * 60 * 60 + 1))
        model.archiveInactiveTabs(now: now, interval: .twentyFourHours)
        #expect(library.item(tab.id) != nil)

        model.archiveInactiveTabs(now: now, interval: .twelveHours)
        #expect(library.item(tab.id) == nil)
        #expect(session.archivedTabs.map(\.item.id) == [tab.id])

        model.reopenArchivedTab(tab.id)
        #expect(library.item(tab.id)?.section == .tabs)
        #expect(session.archivedTabs.isEmpty)
        #expect(session.closedTabs.isEmpty)
        model.reopenClosedTab()
        #expect(library.children(of: nil, section: .tabs, in: spaceID).filter { $0.id == tab.id }.count == 1)
    }

    @Test func playingMediaAndPictureInPictureStayOpen() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let playing = site(library, spaceID: spaceID, title: "Playing", section: .tabs)
        let pip = site(library, spaceID: spaceID, title: "Pip", section: .tabs)
        let keeper = site(library, spaceID: spaceID, title: "Keeper", section: .tabs)
        let old = now.addingTimeInterval(-5 * 24 * 60 * 60)

        model.select(playing.id)
        model.tabs[playing.id]?.isPlayingMedia = true
        model.pictureInPictureTabID = pip.id
        session.selectedItemBySpace[spaceID] = keeper.id
        session.lastActiveAt[playing.id] = old
        session.lastActiveAt[pip.id] = old
        session.lastActiveAt[keeper.id] = now

        model.archiveInactiveTabs(now: now, interval: .twelveHours)

        #expect(library.item(playing.id) != nil)
        #expect(library.item(pip.id) != nil)
        #expect(session.archivedTabs.isEmpty)
    }

    @Test func neverKeepsEveryTab() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tab = site(library, spaceID: spaceID, title: "Old", section: .tabs)
        session.lastActiveAt[tab.id] = now.addingTimeInterval(-400 * 24 * 60 * 60)

        model.archiveInactiveTabs(now: now, interval: .never)

        #expect(library.item(tab.id) != nil)
        #expect(session.archivedTabs.isEmpty)
    }
}

@MainActor
struct TabArchiveSessionTests {
    @Test func roundTripLastActiveAndArchive() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let itemID = UUID()
        // Whole seconds, and recent enough that the 30-day load prune keeps it.
        let stamp = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        let item = SidebarItem(
            id: itemID,
            spaceID: UUID(),
            section: .tabs,
            kind: .site,
            title: "Notes",
            url: URL(string: "https://example.com/notes"),
            sortKey: "a0",
            createdAt: stamp
        )
        store.lastActiveAt = [itemID: stamp]
        store.archivedTabs = [SessionStore.ArchivedTab(
            item: item,
            interactionState: Data([3]),
            archivedAt: stamp,
            lastActiveAt: stamp
        )]
        store.flush()

        let reloaded = SessionStore(directory: directory)
        #expect(reloaded.lastActiveAt[itemID] == stamp)
        #expect(reloaded.archivedTabs.count == 1)
        #expect(reloaded.archivedTabs[0].item.id == itemID)
        #expect(reloaded.archivedTabs[0].item.title == "Notes")
        #expect(reloaded.archivedTabs[0].interactionState == Data([3]))
        #expect(reloaded.archivedTabs[0].archivedAt == stamp)
    }

    @Test func legacySessionFileStillLoads() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")
        let legacy = """
        {
          "closedTabs" : [],
          "interactionStates" : {},
          "isSidebarVisible" : false,
          "schemaVersion" : 1,
          "selectedItemBySpace" : {}
        }
        """
        try legacy.write(to: file, atomically: true, encoding: .utf8)

        let store = SessionStore(directory: directory)
        #expect(store.isSidebarVisible == false)
        #expect(store.closedTabs.isEmpty)
        #expect(store.lastActiveAt.isEmpty)
        #expect(store.archivedTabs.isEmpty)
        #expect(store.selectedSpaceID == nil)
    }

    @Test func loadDropsAnArchiveOlderThanThirtyDays() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let now = Date.now
        store.archivedTabs = [
            archived(title: "Old", archivedAt: now.addingTimeInterval(-(TabArchivePolicy.retention + 3_600))),
            archived(title: "Kept", archivedAt: now.addingTimeInterval(-(TabArchivePolicy.retention - 3_600))),
        ]
        store.flush()

        let reloaded = SessionStore(directory: directory)
        #expect(reloaded.archivedTabs.map(\.item.title) == ["Kept"])
    }

    private func archived(title: String, archivedAt: Date) -> SessionStore.ArchivedTab {
        let item = SidebarItem(
            spaceID: UUID(),
            section: .tabs,
            kind: .site,
            title: title,
            url: URL(string: "https://example.com/\(title)"),
            sortKey: "a0",
            createdAt: archivedAt
        )
        return SessionStore.ArchivedTab(
            item: item,
            interactionState: nil,
            archivedAt: archivedAt,
            lastActiveAt: archivedAt
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "myBrowser-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
