import Foundation
import Testing
import WebKit
@testable import myBrowser

@MainActor
struct SplitViewTests {
    private func makeStore() -> (LibraryStore, Space) {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        return (store, space)
    }

    private func site(
        _ store: LibraryStore,
        spaceID: UUID,
        title: String,
        section: SidebarItem.Section = .tabs,
        parentID: UUID? = nil
    ) -> SidebarItem {
        store.addItem(
            spaceID: spaceID,
            section: section,
            kind: .site,
            parentID: parentID,
            title: title,
            url: URL(string: "https://\(title.lowercased()).example"),
            at: .end
        )
    }

    private func makeModel() -> (BrowserModel, LibraryStore, SessionStore) {
        let library = LibraryStore(directory: nil)
        let session = SessionStore(directory: nil)
        return (BrowserModel(library: library, session: session), library, session)
    }

    // MARK: Store

    @Test func createAddRemoveAndDissolve() throws {
        let (store, space) = makeStore()
        let folder = store.addItem(spaceID: space.id, section: .pinned, kind: .folder, title: "Folder", at: .end)
        let left = site(store, spaceID: space.id, title: "Left", section: .pinned, parentID: folder.id)
        let right = site(store, spaceID: space.id, title: "Right", section: .tabs)
        let extra = site(store, spaceID: space.id, title: "Extra", section: .favorites)
        let loose = site(store, spaceID: space.id, title: "Loose", section: .pinned)
        let otherSpace = store.createSpace(name: "Work")
        let foreign = site(store, spaceID: otherSpace.id, title: "Foreign", section: .tabs)

        #expect(store.createSplit(tabIDs: [left.id]) == nil)
        #expect(store.createSplit(tabIDs: [left.id, left.id]) == nil)
        #expect(store.createSplit(tabIDs: [left.id, extra.id]) == nil)
        #expect(store.createSplit(tabIDs: [left.id, foreign.id]) == nil)
        #expect(store.createSplit(tabIDs: [folder.id, left.id]) == nil)

        let split = try #require(store.createSplit(tabIDs: [left.id, right.id]))
        #expect(split.kind == .split)
        #expect(split.parentID == folder.id)
        #expect(split.section == .pinned)
        #expect(split.spaceID == space.id)
        #expect(split.splitAxis == nil)
        #expect(split.resolvedSplitAxis == .horizontal)
        #expect(split.title == "Left")
        let splitID = split.id
        let members = store.splitMembers(of: splitID)
        #expect(members.map(\.id) == [left.id, right.id])
        #expect(members.allSatisfy { $0.parentID == splitID && $0.section == .pinned && $0.spaceID == space.id })
        #expect(store.splitContainer(of: left.id)?.id == splitID)
        #expect(store.children(of: folder.id, section: .pinned, in: space.id).map(\.id) == [splitID])

        #expect(store.createSplit(tabIDs: [left.id, loose.id]) == nil)
        #expect(store.addToSplit(tabID: foreign.id, splitID: splitID, at: 0) == nil)
        #expect(store.addToSplit(tabID: folder.id, splitID: splitID, at: 0) == nil)
        store.setFractions(splitID: splitID, [1, 1])
        #expect(store.addToSplit(tabID: extra.id, splitID: splitID, at: 0)?.id == extra.id)
        #expect(store.splitMembers(of: splitID).map(\.title) == ["Extra", "Left", "Right"])
        #expect(store.splitMembers(of: splitID).allSatisfy { $0.splitFraction == nil })
        #expect(store.item(extra.id)?.section == .pinned)

        let fourth = site(store, spaceID: space.id, title: "Fourth", section: .tabs)
        #expect(store.addToSplit(tabID: fourth.id, splitID: splitID, at: 99)?.id == fourth.id)
        #expect(store.splitMembers(of: splitID).map(\.title) == ["Extra", "Left", "Right", "Fourth"])
        let fifth = site(store, spaceID: space.id, title: "Fifth", section: .tabs)
        #expect(store.addToSplit(tabID: fifth.id, splitID: splitID, at: 0) == nil)
        store.moveItem(loose.id, to: .pinned, parentID: splitID)
        #expect(store.splitContainer(of: loose.id) == nil)
        #expect(store.canDrop(loose.id, toSpace: space.id, section: .pinned, parentID: splitID) == false)
        #expect(store.canDrop(splitID, toSpace: space.id, section: .favorites, parentID: nil) == false)

        #expect(store.separate(tabID: fourth.id)?.parentID == folder.id)
        #expect(store.splitMembers(of: splitID).map(\.id).contains(fourth.id) == false)
        let roots = store.children(of: folder.id, section: .pinned, in: space.id).map(\.id)
        #expect(roots == [splitID, fourth.id])

        store.separate(tabID: extra.id)
        store.separate(tabID: left.id)
        #expect(store.item(splitID) == nil)
        #expect(store.items[splitID]?.deletedAt != nil)
        #expect(store.item(right.id)?.parentID == folder.id)
        #expect(store.item(right.id)?.section == .pinned)
        #expect(store.item(right.id)?.sortKey == store.items[splitID]?.sortKey)
        #expect(store.splitContainer(of: right.id) == nil)
        #expect(store.children(of: folder.id, section: .pinned, in: space.id).map(\.title).first == "Right")
    }

    @Test func moveSwapAndFractions() {
        let (store, space) = makeStore()
        let titles = ["A", "B", "C", "D"]
        let sites = titles.map { site(store, spaceID: space.id, title: $0) }
        let split = store.createSplit(tabIDs: sites.map(\.id), axis: .vertical)
        let splitID = split!.id
        #expect(store.item(splitID)?.splitAxis == .vertical)

        store.movePane(tabID: sites[0].id, to: 2)
        #expect(store.splitMembers(of: splitID).map(\.title) == ["B", "C", "A", "D"])
        store.movePane(tabID: sites[3].id, to: 1)
        #expect(store.splitMembers(of: splitID).map(\.title) == ["B", "D", "C", "A"])
        let frozen = store.splitMembers(of: splitID).map(\.sortKey)
        store.movePane(tabID: sites[0].id, to: 3)
        #expect(store.splitMembers(of: splitID).map(\.sortKey) == frozen)

        store.setFractions(splitID: splitID, [1, 1, 1, 1])
        store.swapPanes(splitID: splitID, 0, 3)
        let swapped = store.splitMembers(of: splitID)
        #expect(swapped.map(\.title) == ["A", "D", "C", "B"])
        #expect(swapped.map(\.splitFraction) == [0.25, 0.25, 0.25, 0.25])

        store.setFractions(splitID: splitID, [1, 3, 1, 3])
        #expect(store.splitMembers(of: splitID).map(\.splitFraction) == [0.125, 0.375, 0.125, 0.375])
        let kept = store.splitMembers(of: splitID).map(\.splitFraction)
        store.setFractions(splitID: splitID, [1])
        store.setFractions(splitID: splitID, [0, 1, 1, 1])
        store.setFractions(splitID: splitID, [.nan, 1, 1, 1])
        #expect(store.splitMembers(of: splitID).map(\.splitFraction) == kept)
        store.setFractions(splitID: splitID, [])
        #expect(store.splitMembers(of: splitID).allSatisfy { $0.splitFraction == nil })
        #expect(SidebarItem.displayFractions(for: store.splitMembers(of: splitID)).allSatisfy { $0 == nil })

        store.setSplitAxis(splitID: splitID, .horizontal)
        #expect(store.item(splitID)?.splitAxis == .horizontal)
        store.setFractions(splitID: splitID, [1, 1, 1, 1])
        store.addToSplit(tabID: sites[1].id, splitID: splitID, at: 0)
        #expect(store.splitMembers(of: splitID).map(\.title) == ["B", "A", "D", "C"])
        #expect(store.splitMembers(of: splitID).map(\.splitFraction) == [0.25, 0.25, 0.25, 0.25])
    }

    @Test func tabsSplitIsHardDeletedAndPinnedSplitIsTombstoned() {
        let (store, space) = makeStore()
        let tabs = (0..<2).map { site(store, spaceID: space.id, title: "T\($0)") }
        let tabSplit = store.createSplit(tabIDs: tabs.map(\.id))!
        store.deleteItem(tabSplit.id)
        #expect(store.items[tabSplit.id] == nil)
        #expect(tabs.allSatisfy { store.items[$0.id] == nil })

        let pins = (0..<2).map { site(store, spaceID: space.id, title: "P\($0)", section: .pinned) }
        let pinSplit = store.createSplit(tabIDs: pins.map(\.id))!
        store.deleteItem(pinSplit.id)
        #expect(store.item(pinSplit.id) == nil)
        #expect(store.items[pinSplit.id]?.deletedAt != nil)
        #expect(pins.allSatisfy { store.items[$0.id]?.deletedAt != nil })
        let pending = store.pendingChanges(for: [pinSplit.id, pins[0].id, pins[1].id])
        #expect(pending.count == 3)
        #expect(pending.allSatisfy { change in
            if case .delete = change { return true }
            return false
        })

        let live = (0..<2).map { site(store, spaceID: space.id, title: "L\($0)") }
        let dissolving = store.createSplit(tabIDs: live.map(\.id))!
        store.separate(tabID: live[0].id)
        #expect(store.items[dissolving.id] == nil)
        #expect(store.item(live[1].id)?.parentID == nil)
        #expect(store.item(live[1].id)?.section == .tabs)

        let emptyPins = (0..<2).map { site(store, spaceID: space.id, title: "E\($0)", section: .pinned) }
        let empty = store.createSplit(tabIDs: emptyPins.map(\.id))!
        for pin in emptyPins { store.items[pin.id] = nil }
        store.reconcileSplit(empty.id)
        #expect(store.items[empty.id]?.deletedAt != nil)
    }

    @Test func persistRoundTripOmitsNilFieldsAndReadsOlderJSON() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let space = store.createSpace(name: "Personal")
        let left = site(store, spaceID: space.id, title: "Left", section: .pinned)
        let right = site(store, spaceID: space.id, title: "Right", section: .pinned)
        let split = try #require(store.createSplit(tabIDs: [left.id, right.id]))
        store.flush()

        let file = directory.appending(path: "library.json")
        let before = try String(contentsOf: file, encoding: .utf8)
        #expect(!before.contains("splitFraction"))
        #expect(!before.contains("splitAxis"))

        store.setFractions(splitID: split.id, [1, 3])
        store.setSplitAxis(splitID: split.id, .vertical)
        store.flush()
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("\"splitFraction\""))
        #expect(written.contains("\"splitAxis\" : \"vertical\""))

        let reloaded = LibraryStore(directory: directory)
        let members = reloaded.splitMembers(of: split.id)
        #expect(members.map(\.title) == ["Left", "Right"])
        #expect(members.map(\.splitFraction) == [0.25, 0.75])
        #expect(reloaded.item(split.id)?.splitAxis == .vertical)
        #expect(reloaded.item(split.id)?.kind == .split)

        let older = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: older) }
        let profileID = UUID()
        let spaceID = UUID()
        let itemID = UUID()
        let json = """
        {
          "items" : [
            {
              "createdAt" : "2026-01-01T00:00:00Z",
              "id" : "\(itemID.uuidString)",
              "isExpanded" : true,
              "kind" : "site",
              "modifiedAt" : "2026-01-01T00:00:00Z",
              "section" : "pinned",
              "sortKey" : "a0",
              "spaceID" : "\(spaceID.uuidString)",
              "title" : "Old"
            }
          ],
          "profiles" : [
            {
              "id" : "\(profileID.uuidString)",
              "modifiedAt" : "2026-01-01T00:00:00Z",
              "name" : "Personal"
            }
          ],
          "schemaVersion" : 1,
          "spaces" : [
            {
              "color" : "blue",
              "id" : "\(spaceID.uuidString)",
              "modifiedAt" : "2026-01-01T00:00:00Z",
              "name" : "Personal",
              "profileID" : "\(profileID.uuidString)",
              "sortKey" : "a0",
              "symbol" : "circle.fill"
            }
          ]
        }
        """
        try json.write(to: older.appending(path: "library.json"), atomically: true, encoding: .utf8)
        let opened = LibraryStore(directory: older)
        let old = try #require(opened.item(itemID))
        #expect(old.title == "Old")
        #expect(old.splitFraction == nil)
        #expect(old.splitAxis == nil)
        #expect(old.kind == .site)
    }

    @Test func sessionFocusSurvivesRelaunchAndOlderFiles() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let splitID = UUID()
        let paneID = UUID()
        let store = SessionStore(directory: directory)
        store.focusedPaneBySplit = [splitID: paneID]
        store.flush()
        let reloaded = SessionStore(directory: directory)
        #expect(reloaded.focusedPaneBySplit == [splitID: paneID])

        let older = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: older) }
        let spaceID = UUID()
        // UUID-keyed dictionaries encode as alternating arrays. Older files omit focusedPaneBySplit.
        let json = """
        {
          "closedTabs" : [],
          "interactionStates" : [],
          "isSidebarVisible" : true,
          "schemaVersion" : 1,
          "selectedItemBySpace" : [],
          "selectedSpaceID" : "\(spaceID.uuidString)"
        }
        """
        try json.write(to: older.appending(path: "session.json"), atomically: true, encoding: .utf8)
        let opened = SessionStore(directory: older)
        #expect(opened.selectedSpaceID == spaceID)
        #expect(opened.focusedPaneBySplit.isEmpty)
    }

    @Test func syncMapsPinnedSplitsAndSkipsTabSplits() throws {
        let spaceID = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        var split = SidebarItem(
            id: UUID(),
            spaceID: spaceID,
            section: .pinned,
            kind: .split,
            title: "Left",
            sortKey: "a0",
            splitAxis: .horizontal,
            createdAt: created
        )
        split.modifiedAt = created
        var member = SidebarItem(
            id: UUID(),
            spaceID: spaceID,
            section: .pinned,
            kind: .site,
            parentID: split.id,
            title: "Left",
            url: URL(string: "https://left.example"),
            sortKey: "a0",
            splitFraction: 0.25,
            createdAt: created
        )
        member.modifiedAt = created
        let tabSplit = SidebarItem(
            spaceID: spaceID,
            section: .tabs,
            kind: .split,
            title: "Tabs",
            sortKey: "a0",
            createdAt: created
        )

        let splitRecord = try #require(RecordMapper.record(for: split))
        let memberRecord = try #require(RecordMapper.record(for: member))
        #expect(RecordMapper.item(from: splitRecord) == split)
        #expect(RecordMapper.item(from: memberRecord) == member)
        #expect(splitRecord[RecordMapper.Field.splitAxis] as? String == "horizontal")
        #expect(RecordMapper.record(for: tabSplit) == nil)

        var bare = split
        bare.splitAxis = nil
        let bareRecord = try #require(RecordMapper.record(for: bare))
        #expect(bareRecord[RecordMapper.Field.splitAxis] == nil)
        #expect(bareRecord[RecordMapper.Field.splitFraction] == nil)
        #expect(RecordMapper.item(from: bareRecord)?.splitAxis == nil)
    }

    // MARK: Browser model

    @Test func browserAPISelectsFocusesAndRestores() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let favorite = site(library, spaceID: spaceID, title: "Fav", section: .favorites)
        let left = site(library, spaceID: spaceID, title: "Left")
        let right = site(library, spaceID: spaceID, title: "Right")
        let third = site(library, spaceID: spaceID, title: "Third")
        let outside = site(library, spaceID: spaceID, title: "Outside")

        let split = try #require(library.createSplit(tabIDs: [left.id, right.id]))
        let preview = try #require(model.displayedContent(for: split.id))
        #expect(preview.isSplit)
        #expect(preview.itemID == split.id)
        #expect(preview.panes.map(\.id) == [left.id, right.id])
        #expect(preview.focusedID == left.id)
        #expect(preview.panes.allSatisfy { $0.tab.isLoaded == false })
        #expect(model.displayedContent(for: left.id)?.itemID == split.id)
        #expect(model.displayedContent(for: left.id)?.focusedID == left.id)
        #expect(model.displayedContent(for: favorite.id)?.isSplit == false)

        model.select(right.id)
        #expect(model.selectedItemID == split.id)
        #expect(model.selectedTab?.id == right.id)
        #expect(model.tabs[left.id]?.isLoaded == true)
        #expect(model.tabs[right.id]?.isLoaded == true)

        model.select(outside.id)
        model.select(split.id)
        #expect(model.selectedTab?.id == right.id)

        model.select(third.id)
        model.addToSplit(tabID: third.id, splitID: split.id, at: 0)
        #expect(model.selectedItemID == split.id)
        #expect(model.selectedTab?.id == third.id)
        #expect(model.tabs[third.id]?.isLoaded == true)
        #expect(library.splitMembers(of: split.id).map(\.title) == ["Third", "Left", "Right"])

        model.selectNextTab()
        #expect(model.selectedItemID == split.id)
        #expect(model.selectedTab?.id == left.id)
        #expect(model.navigableItems.map(\.title) == ["Fav", "Third", "Left", "Right", "Outside"])
        #expect(model.navigableItems.allSatisfy { !$0.isSplit })
        #expect(CommandBarModel.matchRank(item: library.item(split.id)!, query: "Left") == nil)
        let matches = CommandBarModel.rankedMatches(
            query: "t",
            items: [library.item(split.id)!, library.item(left.id)!, library.item(right.id)!, library.item(third.id)!]
        )
        #expect(matches.map(\.id).contains(split.id) == false)
        #expect(Set(matches.map(\.id)) == Set([left.id, right.id, third.id]))

        model.focusPane(tabID: right.id)
        #expect(model.selectedTab?.id == right.id)
        model.separate(tabID: right.id)
        #expect(model.selectedItemID == right.id)
        #expect(library.splitContainer(of: right.id) == nil)
        #expect(library.item(split.id)?.isSplit == true)

        model.select(split.id)
        model.close(split.id)
        #expect(session.closedTabs.last?.item.id == third.id)
        #expect(session.closedTabs.last?.item.parentID == nil)
        #expect(session.closedTabs.last?.item.splitFraction == nil)
        #expect(library.item(split.id) == nil)
        #expect(library.items[split.id] == nil)
        #expect(model.selectedItemID == left.id)

        let pinnedLeft = site(library, spaceID: spaceID, title: "PLeft", section: .pinned)
        let pinnedRight = site(library, spaceID: spaceID, title: "PRight", section: .pinned)
        let pinned = try #require(model.createSplit(tabIDs: [pinnedLeft.id, pinnedRight.id]))
        #expect(model.selectedItemID == pinned.id)
        #expect(model.tabs[pinnedLeft.id]?.isLoaded == true)
        #expect(model.tabs[pinnedRight.id]?.isLoaded == true)
        model.close(pinnedLeft.id)
        #expect(library.item(pinnedLeft.id) != nil)
        #expect(model.tabs[pinnedLeft.id] == nil)
        #expect(model.tabs[pinnedRight.id]?.isLoaded == true)
        #expect(model.selectedItemID == pinned.id)
        #expect(model.selectedTab?.id == pinnedRight.id)

        model.select(outside.id)
        model.select(pinned.id)
        #expect(model.tabs[pinnedLeft.id]?.isLoaded == true)

        session.focusedPaneBySplit[UUID()] = UUID()
        model.saveState()
        #expect(session.focusedPaneBySplit == [pinned.id: pinnedRight.id])

        session.focusedPaneBySplit[pinned.id] = pinnedLeft.id
        let restored = BrowserModel(library: library, session: session)
        #expect(restored.selectedItemID == pinned.id)
        #expect(restored.selectedTab?.id == pinnedLeft.id)
        #expect(restored.tabs[pinnedLeft.id]?.isLoaded == true)
        #expect(restored.tabs[pinnedRight.id]?.isLoaded == true)
    }

    @Test func deleteSplitRemovesMembersAndSelectsTheNeighbour() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let keeper = site(library, spaceID: spaceID, title: "Keeper")
        let left = site(library, spaceID: spaceID, title: "Left", section: .pinned)
        let right = site(library, spaceID: spaceID, title: "Right", section: .pinned)
        let split = try #require(model.createSplit(tabIDs: [left.id, right.id]))
        model.delete(split.id)
        #expect(library.item(split.id) == nil)
        #expect(library.items[left.id]?.deletedAt != nil)
        #expect(library.items[right.id]?.deletedAt != nil)
        #expect(model.tabs[left.id] == nil)
        #expect(model.selectedItemID == keeper.id)
        #expect(session.closedTabs.isEmpty)
    }

    @Test func openInSplitViewFocusesABlankPane() throws {
        let (model, library, _) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let page = site(library, spaceID: spaceID, title: "Page")
        model.select(page.id)
        #expect(model.openInSplitView())
        let splitID = try #require(model.selectedItemID)
        let members = library.splitMembers(of: splitID)
        #expect(members.map(\.id).first == page.id)
        #expect(members.count == 2)
        #expect(members[1].title == "New Tab")
        #expect(members[1].url == nil)
        #expect(model.resolvedFocus(in: splitID) == members[1].id)
        #expect(model.commandBarMode == .editCurrent)
        #expect(model.selectedTab?.id == members[1].id)
    }

    @Test func separateAllKeepsPaneOrder() throws {
        let (model, library, _) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let first = site(library, spaceID: spaceID, title: "First")
        let second = site(library, spaceID: spaceID, title: "Second")
        let third = site(library, spaceID: spaceID, title: "Third")
        let split = try #require(model.createSplit(tabIDs: [first.id, second.id, third.id]))
        model.separateAllPanes()
        #expect(library.item(split.id)?.isSplit != true)
        let roots = library.children(of: nil, section: .tabs, in: spaceID)
        #expect(roots.map(\.id) == [first.id, second.id, third.id])
        #expect(roots.allSatisfy { $0.kind == .site && $0.parentID == nil })
    }

    @Test func focusAndSwapMoveAmongPanes() throws {
        let (model, library, _) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let first = site(library, spaceID: spaceID, title: "First")
        let second = site(library, spaceID: spaceID, title: "Second")
        let third = site(library, spaceID: spaceID, title: "Third")
        model.select(first.id)
        let split = try #require(model.createSplit(tabIDs: [first.id, second.id, third.id]))
        #expect(model.resolvedFocus(in: split.id) == first.id)
        model.focusAdjacentPane(offset: 1)
        #expect(model.resolvedFocus(in: split.id) == second.id)
        model.focusAdjacentPane(offset: -1)
        #expect(model.resolvedFocus(in: split.id) == first.id)
        model.focusAdjacentPane(offset: -1)
        #expect(model.resolvedFocus(in: split.id) == third.id)
        #expect(model.canSwapPanes == false)
        model.separate(tabID: third.id)
        #expect(library.splitMembers(of: split.id).count == 2)
        model.select(split.id)
        model.swapFocusedPanes()
        #expect(library.splitMembers(of: split.id).map(\.id) == [second.id, first.id])
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "myBrowser-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
