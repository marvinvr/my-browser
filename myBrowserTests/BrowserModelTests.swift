import Foundation
import Testing
@testable import myBrowser

@MainActor
struct BrowserModelTests {
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
            kind: .site,
            parentID: parentID,
            title: title,
            url: URL(string: "https://\(title.lowercased()).example"),
            at: .end
        )
    }

    @Test func navigableItemsWalkExpandedFoldersOnly() throws {
        let (model, library, _) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)

        _ = site(library, spaceID: spaceID, title: "F1", section: .favorites)
        _ = site(library, spaceID: spaceID, title: "F2", section: .favorites)

        let folderA = library.addItem(spaceID: spaceID, section: .pinned, kind: .folder, title: "A", at: .end)
        _ = site(library, spaceID: spaceID, title: "A1", section: .pinned, parentID: folderA.id)
        let folderB = library.addItem(
            spaceID: spaceID, section: .pinned, kind: .folder, parentID: folderA.id, title: "B", at: .end
        )
        library.updateItem(folderB.id) { $0.isExpanded = false }
        _ = site(library, spaceID: spaceID, title: "B1", section: .pinned, parentID: folderB.id)
        _ = site(library, spaceID: spaceID, title: "A2", section: .pinned, parentID: folderA.id)

        _ = site(library, spaceID: spaceID, title: "C", section: .pinned)

        let folderD = library.addItem(spaceID: spaceID, section: .pinned, kind: .folder, title: "D", at: .end)
        library.updateItem(folderD.id) { $0.isExpanded = false }
        _ = site(library, spaceID: spaceID, title: "D1", section: .pinned, parentID: folderD.id)

        _ = site(library, spaceID: spaceID, title: "T1", section: .tabs)
        _ = site(library, spaceID: spaceID, title: "T2", section: .tabs)

        #expect(model.navigableItems.map(\.title) == ["F1", "F2", "A1", "A2", "C", "T1", "T2"])

        model.toggleExpanded(folderB.id)
        #expect(model.navigableItems.map(\.title) == ["F1", "F2", "A1", "B1", "A2", "C", "T1", "T2"])
    }

    @Test func closeAndReopenRestoresTheItemAndItsHistory() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let url = URL(string: "https://example.com/docs")!
        let keeper = site(library, spaceID: spaceID, title: "Keeper", section: .tabs)
        let closing = library.addItem(
            spaceID: spaceID, section: .tabs, title: "Docs", url: url, at: .end
        )
        let history = Data([0x01, 0x02, 0x03])
        session.interactionStates[closing.id] = history
        session.selectedItemBySpace[spaceID] = closing.id

        model.close(closing.id)

        #expect(library.item(closing.id) == nil)
        #expect(session.closedTabs.count == 1)
        #expect(session.closedTabs.last?.item.title == "Docs")
        #expect(session.closedTabs.last?.item.url == url)
        #expect(session.closedTabs.last?.interactionState == history)
        #expect(model.selectedItemID == keeper.id)

        model.reopenClosedTab()

        let restored = library.item(closing.id)
        #expect(restored?.title == "Docs")
        #expect(restored?.url == url)
        #expect(restored?.section == .tabs)
        #expect(session.interactionStates[closing.id] == history)
        let tabs = library.children(of: nil, section: .tabs, in: spaceID)
        #expect(tabs.map(\.id).contains(closing.id))
        #expect(tabs.map(\.id).contains(keeper.id))
        let restoredKey = library.item(closing.id)?.sortKey
        #expect(restoredKey == SortKey.between(nil, keeper.sortKey))
        #expect((restoredKey ?? "") < keeper.sortKey)
        #expect(model.selectedItemID == closing.id)
    }

    @Test func pinAndUnpinMoveSections() throws {
        let (model, library, _) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let stay = site(library, spaceID: spaceID, title: "Stay", section: .pinned)
        let moving = library.addItem(
            spaceID: spaceID,
            section: .tabs,
            title: "Move",
            url: URL(string: "https://move.example/path"),
            at: .end
        )
        let other = site(library, spaceID: spaceID, title: "Other", section: .tabs)

        model.pin(moving.id)

        let pinned = library.children(of: nil, section: .pinned, in: spaceID)
        #expect(pinned.map(\.id) == [stay.id, moving.id])
        #expect(library.item(moving.id)?.section == .pinned)
        #expect(library.item(moving.id)?.url == URL(string: "https://move.example/path"))
        #expect(library.children(of: nil, section: .tabs, in: spaceID).map(\.id) == [other.id])

        model.unpin(moving.id)

        #expect(library.item(moving.id)?.section == .tabs)
        #expect(library.item(moving.id)?.url == URL(string: "https://move.example/path"))
        let tabs = library.children(of: nil, section: .tabs, in: spaceID)
        #expect(tabs.map(\.title).contains("Move"))
        #expect(tabs.map(\.title).contains("Other"))
        let unpinnedKey = library.item(moving.id)?.sortKey
        #expect(unpinnedKey == SortKey.between(nil, other.sortKey))
        #expect((unpinnedKey ?? "") < other.sortKey)
    }

    @Test func deleteUnloadsTheTabAndMovesSelection() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let keeper = site(library, spaceID: spaceID, title: "Keeper", section: .pinned)
        let doomed = site(library, spaceID: spaceID, title: "Doomed", section: .pinned)
        model.select(doomed.id)
        #expect(model.tabs[doomed.id]?.isLoaded == true)

        model.delete(doomed.id)

        #expect(library.item(doomed.id) == nil)
        #expect(model.tabs[doomed.id] == nil)
        #expect(model.selectedItemID == keeper.id)
        #expect(session.closedTabs.isEmpty)
    }

    @Test func deleteFolderUnloadsDescendantTabs() throws {
        let (model, library, session) = makeModel()
        let spaceID = try #require(model.selectedSpace?.id)
        let keeper = site(library, spaceID: spaceID, title: "Keeper", section: .tabs)
        let folder = library.addItem(spaceID: spaceID, section: .pinned, kind: .folder, title: "Folder", at: .end)
        let child = site(library, spaceID: spaceID, title: "Child", section: .pinned, parentID: folder.id)
        model.select(child.id)

        model.delete(folder.id)

        #expect(library.item(folder.id) == nil)
        #expect(library.item(child.id) == nil)
        #expect(model.tabs[child.id] == nil)
        #expect(model.selectedItemID == keeper.id)
        #expect(session.closedTabs.isEmpty)
    }

    @Test func spaceNextAndPreviousWrap() throws {
        let (model, _, _) = makeModel()
        let personal = try #require(model.selectedSpace?.id)
        let work = model.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)
        #expect(model.selectedSpaceID == work.id)

        model.selectNextSpace()
        #expect(model.selectedSpaceID == personal)

        model.selectNextSpace()
        #expect(model.selectedSpaceID == work.id)

        model.selectPreviousSpace()
        #expect(model.selectedSpaceID == personal)
    }

    @Test func deleteSpaceRefusesTheLastOne() throws {
        let (model, library, _) = makeModel()
        let personal = try #require(model.selectedSpace?.id)
        model.deleteSpace(personal)
        #expect(library.space(personal) != nil)
        #expect(library.orderedSpaces.count == 1)

        let work = model.createSpace(name: "Work", symbol: "briefcase.fill", color: .red)
        model.selectSpace(personal)
        model.deleteSpace(personal)
        #expect(library.space(personal) == nil)
        #expect(model.selectedSpaceID == work.id)
        #expect(library.orderedSpaces.map(\.id) == [work.id])

        model.deleteSpace(work.id)
        #expect(library.space(work.id) != nil)
        #expect(model.selectedSpaceID == work.id)
    }
}
