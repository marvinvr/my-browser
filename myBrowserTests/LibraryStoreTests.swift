import Foundation
import Testing
@testable import myBrowser

@MainActor
struct LibraryStoreTests {
    @Test func createSpaceCreatesAProfile() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)

        let profile = store.profile(space.profileID)
        #expect(profile?.name == "Work")
        #expect(profile?.id == space.profileID)
        #expect(store.profiles.count == 1)
        #expect(store.space(space.id)?.profileID == profile?.id)
    }

    /// `.end` only. `SortKey.between` is still a stub that appends "V", so each appended key grows and stays ordered.
    @Test func appendingAtEndKeepsChildOrder() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let titles = ["One", "Two", "Three"]
        let added = titles.map { title in
            store.addItem(spaceID: space.id, section: .pinned, title: title, at: .end)
        }

        let children = store.children(of: nil, section: .pinned, in: space.id)
        #expect(children.map(\.id) == added.map(\.id))
        #expect(children.map(\.title) == titles)
        #expect(added[0].sortKey < added[1].sortKey)
        #expect(added[1].sortKey < added[2].sortKey)
    }

    @Test func deleteItemTombstonesPinnedAndHardDeletesTabs() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let pinned = store.addItem(spaceID: space.id, section: .pinned, title: "Pinned")
        let tab = store.addItem(spaceID: space.id, section: .tabs, title: "Tab")

        store.deleteItem(pinned.id)
        store.deleteItem(tab.id)

        #expect(store.item(pinned.id) == nil)
        #expect(store.items[pinned.id]?.deletedAt != nil)
        #expect(store.children(of: nil, section: .pinned, in: space.id).isEmpty)
        #expect(store.items[tab.id] == nil)
        #expect(store.children(of: nil, section: .tabs, in: space.id).isEmpty)
    }
}
