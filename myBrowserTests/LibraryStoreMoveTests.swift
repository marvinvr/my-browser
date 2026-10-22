import Foundation
import Testing
@testable import myBrowser

@MainActor
struct LibraryStoreMoveTests {
    private func spacePair() -> (LibraryStore, Space, Space) {
        let store = LibraryStore(directory: nil)
        let home = store.createSpace(name: "Personal")
        let work = store.createSpace(name: "Work")
        return (store, home, work)
    }

    @Test func folderCannotDropIntoItselfOrADescendant() {
        let (store, home, _) = spacePair()
        let folder = store.addItem(spaceID: home.id, section: .pinned, kind: .folder, title: "Folder")
        let child = store.addItem(spaceID: home.id, section: .pinned, kind: .folder, parentID: folder.id, title: "Child")
        let key = store.item(folder.id)?.sortKey

        #expect(store.canDrop(folder.id, toSpace: home.id, section: .pinned, parentID: folder.id) == false)
        #expect(store.canDrop(folder.id, toSpace: home.id, section: .pinned, parentID: child.id) == false)
        #expect(store.canDrop(child.id, toSpace: home.id, section: .pinned, parentID: folder.id) == true)

        var batches: [Set<UUID>] = []
        store.onChange = { batches.append($0) }
        store.move(folder.id, toSpace: home.id, section: .pinned, parentID: child.id, position: .end)

        #expect(batches.isEmpty)
        #expect(store.item(folder.id)?.parentID == nil)
        #expect(store.item(folder.id)?.sortKey == key)
        #expect(store.item(child.id)?.parentID == folder.id)
    }

    @Test func foldersStayOutOfFlatSectionsAndSitesMayEnterFavorites() {
        let (store, home, _) = spacePair()
        let folder = store.addItem(spaceID: home.id, section: .pinned, kind: .folder, title: "Folder")
        let site = store.addItem(spaceID: home.id, section: .tabs, title: "Site", url: URL(string: "https://example.com"))

        #expect(store.canDrop(folder.id, toSpace: home.id, section: .favorites, parentID: nil) == false)
        #expect(store.canDrop(folder.id, toSpace: home.id, section: .tabs, parentID: nil) == false)
        #expect(store.canDrop(site.id, toSpace: home.id, section: .favorites, parentID: nil) == true)
        #expect(store.canDrop(site.id, toSpace: home.id, section: .favorites, parentID: folder.id) == false)

        store.move(folder.id, toSpace: home.id, section: .favorites, position: .start)
        store.move(folder.id, toSpace: home.id, section: .tabs, position: .start)
        #expect(store.item(folder.id)?.section == .pinned)

        store.move(site.id, toSpace: home.id, section: .favorites, position: .end)
        #expect(store.item(site.id)?.section == .favorites)
        #expect(store.item(site.id)?.parentID == nil)
    }

    @Test func crossSpaceSubtreeMoveIsOneChangeAndKeepsParents() {
        let (store, home, work) = spacePair()
        let existing = store.addItem(spaceID: work.id, section: .pinned, title: "Existing", url: URL(string: "https://keep.example"))
        let folder = store.addItem(spaceID: home.id, section: .pinned, kind: .folder, title: "Folder")
        let child = store.addItem(spaceID: home.id, section: .pinned, kind: .folder, parentID: folder.id, title: "Child")
        let leaf = store.addItem(
            spaceID: home.id, section: .pinned, parentID: child.id, title: "Leaf", url: URL(string: "https://leaf.example")
        )

        var batches: [Set<UUID>] = []
        store.onChange = { batches.append($0) }
        store.move(folder.id, toSpace: work.id, section: .pinned, parentID: nil, position: .start)

        #expect(batches.count == 1)
        #expect(batches[0] == [folder.id, child.id, leaf.id])
        #expect(store.item(folder.id)?.spaceID == work.id)
        #expect(store.item(child.id)?.spaceID == work.id)
        #expect(store.item(leaf.id)?.spaceID == work.id)
        #expect(store.item(folder.id)?.section == .pinned)
        #expect(store.item(child.id)?.section == .pinned)
        #expect(store.item(leaf.id)?.section == .pinned)
        #expect(store.item(child.id)?.parentID == folder.id)
        #expect(store.item(leaf.id)?.parentID == child.id)
        let pinned = store.children(of: nil, section: .pinned, in: work.id).map(\.id)
        #expect(pinned == [folder.id, existing.id])
        #expect(store.children(of: nil, section: .pinned, in: home.id).isEmpty)
    }

    @Test func beforeAndAfterReorderSiblings() {
        let (store, home, _) = spacePair()
        let first = store.addItem(spaceID: home.id, section: .tabs, title: "One", url: URL(string: "https://one.example"))
        let second = store.addItem(spaceID: home.id, section: .tabs, title: "Two", url: URL(string: "https://two.example"))
        let third = store.addItem(spaceID: home.id, section: .tabs, title: "Three", url: URL(string: "https://three.example"))

        store.move(third.id, toSpace: home.id, section: .tabs, position: .before(second.id))
        #expect(store.children(of: nil, section: .tabs, in: home.id).map(\.id) == [first.id, third.id, second.id])

        store.move(first.id, toSpace: home.id, section: .tabs, position: .after(third.id))
        #expect(store.children(of: nil, section: .tabs, in: home.id).map(\.id) == [third.id, first.id, second.id])

        let key = store.item(second.id)?.sortKey
        store.move(second.id, toSpace: home.id, section: .tabs, position: .before(second.id))
        #expect(store.item(second.id)?.sortKey == key)
    }

    @Test func spaceDropKeepsASiteSectionAndSendsFoldersToPinned() {
        let (store, home, _) = spacePair()
        let folder = store.addItem(spaceID: home.id, section: .pinned, kind: .folder, title: "Folder")
        let pin = store.addItem(spaceID: home.id, section: .pinned, title: "Pin", url: URL(string: "https://pin.example"))
        let tab = store.addItem(spaceID: home.id, section: .tabs, title: "Tab", url: URL(string: "https://tab.example"))
        let favorite = store.addItem(spaceID: home.id, section: .favorites, title: "Fav", url: URL(string: "https://fav.example"))

        #expect(store.sectionForSpaceDrop(folder) == .pinned)
        #expect(store.sectionForSpaceDrop(pin) == .pinned)
        #expect(store.sectionForSpaceDrop(tab) == .tabs)
        #expect(store.sectionForSpaceDrop(favorite) == .favorites)
    }
}
