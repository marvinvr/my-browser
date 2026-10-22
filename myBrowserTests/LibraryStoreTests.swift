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

    @Test func deleteFolderTombstonesSubtree() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let folder = store.addItem(spaceID: space.id, section: .pinned, kind: .folder, title: "Folder")
        let sub = store.addItem(spaceID: space.id, section: .pinned, kind: .folder, parentID: folder.id, title: "Sub")
        let leaf = store.addItem(spaceID: space.id, section: .pinned, parentID: sub.id, title: "Leaf", url: URL(string: "https://example.com"))

        store.deleteItem(folder.id)

        #expect(store.item(folder.id) == nil)
        #expect(store.item(sub.id) == nil)
        #expect(store.item(leaf.id) == nil)
        #expect(store.items[folder.id]?.deletedAt != nil)
        #expect(store.items[sub.id]?.deletedAt != nil)
        #expect(store.items[leaf.id]?.deletedAt != nil)
        #expect(store.children(of: nil, section: .pinned, in: space.id).isEmpty)
    }

    @Test func moveFolderMovesSubtreeSectionAndRejectsFlatSections() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let folder = store.addItem(spaceID: space.id, section: .tabs, kind: .folder, title: "Folder")
        let sub = store.addItem(spaceID: space.id, section: .tabs, kind: .folder, parentID: folder.id, title: "Sub")
        let leaf = store.addItem(spaceID: space.id, section: .tabs, parentID: sub.id, title: "Leaf", url: URL(string: "https://example.com/leaf"))

        store.moveItem(folder.id, to: .pinned, at: .end)

        #expect(store.item(folder.id)?.section == .pinned)
        #expect(store.item(sub.id)?.section == .pinned)
        #expect(store.item(leaf.id)?.section == .pinned)
        #expect(store.item(sub.id)?.parentID == folder.id)
        #expect(store.item(leaf.id)?.parentID == sub.id)
        #expect(store.children(of: folder.id, section: .pinned, in: space.id).map(\.id) == [sub.id])
        #expect(store.children(of: folder.id, section: .tabs, in: space.id).isEmpty)

        let pinnedKey = store.item(folder.id)?.sortKey
        store.moveItem(folder.id, to: .favorites, at: .start)
        store.moveItem(folder.id, to: .tabs, at: .start)
        #expect(store.item(folder.id)?.section == .pinned)
        #expect(store.item(folder.id)?.sortKey == pinnedKey)
        #expect(store.item(sub.id)?.section == .pinned)
        #expect(store.item(leaf.id)?.section == .pinned)

        store.moveItem(leaf.id, to: .favorites)
        #expect(store.item(leaf.id)?.section == .favorites)
        #expect(store.item(leaf.id)?.parentID == nil)
        #expect(store.item(sub.id)?.section == .pinned)

        store.moveItem(leaf.id, to: .tabs, parentID: folder.id)
        #expect(store.item(leaf.id)?.section == .tabs)
        #expect(store.item(leaf.id)?.parentID == nil)
    }

    @Test func deleteSpaceTombstonesUnusedProfileOnly() {
        let store = LibraryStore(directory: nil)
        let work = store.createSpace(name: "Work")
        let personal = store.createSpace(name: "Personal")
        let personalProfile = personal.profileID
        let pinned = store.addItem(spaceID: work.id, section: .pinned, title: "Pin")
        let tab = store.addItem(spaceID: work.id, section: .tabs, title: "Tab")
        store.updateSpace(personal.id) { $0.profileID = work.profileID }

        store.deleteSpace(personal.id)
        #expect(store.space(personal.id) == nil)
        #expect(store.spaces[personal.id]?.deletedAt != nil)
        #expect(store.profile(work.profileID) != nil)
        #expect(store.profiles[personalProfile]?.deletedAt == nil)

        store.deleteSpace(work.id)
        #expect(store.space(work.id) == nil)
        #expect(store.profile(work.profileID) == nil)
        #expect(store.profiles[work.profileID]?.deletedAt != nil)
        #expect(store.items[pinned.id]?.deletedAt != nil)
        #expect(store.items[tab.id] == nil)
    }

    @Test func purgeTombstonesRemovesOnlyOldRecords() {
        let store = LibraryStore(directory: nil)
        let live = store.createSpace(name: "Live")
        let old = store.createSpace(name: "Old")
        let item = store.addItem(spaceID: old.id, section: .pinned, title: "Gone")
        store.deleteSpace(old.id)

        store.purgeTombstones(olderThan: .now.addingTimeInterval(-60))
        #expect(store.spaces[old.id] != nil)
        #expect(store.space(live.id) != nil)

        let longAgo = Date.now.addingTimeInterval(-31 * 24 * 60 * 60)
        store.updateSpace(old.id) { $0.deletedAt = longAgo }
        store.updateItem(item.id) { $0.deletedAt = longAgo }
        store.purgeTombstones()
        #expect(store.spaces[old.id] == nil)
        #expect(store.items[item.id] == nil)
        #expect(store.profiles[old.profileID]?.deletedAt != nil)
        #expect(store.space(live.id)?.name == "Live")

        store.purgeTombstones(olderThan: .now.addingTimeInterval(1))
        #expect(store.profiles[old.profileID] == nil)
        #expect(store.space(live.id) != nil)
    }

    @Test func onChangeReportsMutatedIDs() {
        let store = LibraryStore(directory: nil)
        var batches: [Set<UUID>] = []
        store.onChange = { batches.append($0) }

        let space = store.createSpace(name: "Work")
        #expect(batches[0].contains(space.id))
        #expect(batches[0].contains(space.profileID))

        let item = store.addItem(spaceID: space.id, section: .pinned, title: "Pin")
        #expect(batches.last == [item.id])

        store.deleteSpace(space.id)
        let deleted = batches.last ?? []
        #expect(deleted.contains(space.id))
        #expect(deleted.contains(space.profileID))
        #expect(deleted.contains(item.id))
    }

    @Test func nilDirectoryNeverTouchesDisk() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Memory")
        store.addItem(spaceID: space.id, section: .pinned, title: "Pin")
        store.flush()
        #expect(store.space(space.id)?.name == "Memory")
    }

    @Test func roundTripPersistsTombstonesAndSortsRecords() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")

        let store = LibraryStore(directory: directory)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        let work = store.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)
        let personal = store.createSpace(name: "Personal", symbol: "person.fill", color: .teal)
        let folder = store.addItem(spaceID: work.id, section: .pinned, kind: .folder, title: "Folder")
        let page = store.addItem(
            spaceID: work.id,
            section: .pinned,
            parentID: folder.id,
            title: "Example",
            url: URL(string: "https://example.com/docs")
        )
        let tab = store.addItem(spaceID: work.id, section: .tabs, title: "Tab", url: URL(string: "https://example.com/tab"))
        let removed = store.addItem(spaceID: personal.id, section: .favorites, title: "Old", url: URL(string: "https://example.com/old"))
        store.deleteItem(removed.id)
        store.flush()

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\" : 1"))
        let itemsKey = try #require(text.range(of: "\"items\""))
        let profilesKey = try #require(text.range(of: "\"profiles\""))
        let schemaKey = try #require(text.range(of: "\"schemaVersion\""))
        let spacesKey = try #require(text.range(of: "\"spaces\""))
        #expect(itemsKey.lowerBound < profilesKey.lowerBound)
        #expect(profilesKey.lowerBound < schemaKey.lowerBound)
        #expect(schemaKey.lowerBound < spacesKey.lowerBound)

        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let itemIDs = (object["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        let profileIDs = (object["profiles"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        let spaceIDs = (object["spaces"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        #expect(itemIDs == itemIDs?.sorted())
        #expect(profileIDs == profileIDs?.sorted())
        #expect(spaceIDs == spaceIDs?.sorted())
        let modified = (object["spaces"] as? [[String: Any]])?.first?["modifiedAt"] as? String
        #expect(modified?.contains("T") == true)
        #expect(modified?.hasSuffix("Z") == true)

        let reloaded = LibraryStore(directory: directory)
        #expect(reloaded.space(work.id)?.name == "Work")
        #expect(reloaded.space(work.id)?.symbol == "briefcase.fill")
        #expect(reloaded.space(work.id)?.color == .orange)
        #expect(reloaded.space(work.id)?.profileID == work.profileID)
        #expect(reloaded.profile(work.profileID)?.name == "Work")
        #expect(reloaded.space(personal.id)?.color == .teal)
        #expect(reloaded.item(folder.id)?.isFolder == true)
        #expect(reloaded.item(page.id)?.url == URL(string: "https://example.com/docs"))
        #expect(reloaded.item(page.id)?.parentID == folder.id)
        #expect(reloaded.item(page.id)?.sortKey == page.sortKey)
        #expect(reloaded.item(tab.id)?.section == .tabs)
        #expect(reloaded.item(removed.id) == nil)
        #expect(reloaded.items[removed.id]?.deletedAt != nil)
        #expect(reloaded.children(of: nil, section: .favorites, in: personal.id).isEmpty)
        #expect(reloaded.ensureDefaultSpace().id == reloaded.orderedSpaces.first?.id)

        let again = try String(contentsOf: file, encoding: .utf8)
        #expect(again == text)
    }

    @Test func missingFileStartsEmptyAndCorruptFileIsQuarantined() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")

        let missing = LibraryStore(directory: directory)
        #expect(missing.spaces.isEmpty)
        #expect(missing.profiles.isEmpty)
        #expect(missing.items.isEmpty)

        try "{".write(to: file, atomically: true, encoding: .utf8)
        let corrupt = LibraryStore(directory: directory)
        #expect(corrupt.spaces.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("library.corrupt-") && $0.hasSuffix(".json") })

        try """
        {
          "items" : [],
          "profiles" : [],
          "schemaVersion" : 2,
          "spaces" : []
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        let future = LibraryStore(directory: directory)
        #expect(future.spaces.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        let space = future.createSpace(name: "Recovered")
        future.flush()
        let reloaded = LibraryStore(directory: directory)
        #expect(reloaded.space(space.id)?.name == "Recovered")
    }

    @Test func debouncedSaveWritesLatestStateAndFlushIsImmediate() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let store = LibraryStore(directory: directory)

        let started = ContinuousClock.now
        let first = store.createSpace(name: "One")
        store.createSpace(name: "Two")
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        store.flush()
        #expect(ContinuousClock.now - started < .milliseconds(400))
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        store.updateSpace(first.id) { $0.name = "One renamed" }
        let afterFlush = try String(contentsOf: file, encoding: .utf8)
        #expect(!afterFlush.contains("One renamed"))
        try await Task.sleep(for: .milliseconds(1200))
        let settled = try String(contentsOf: file, encoding: .utf8)
        #expect(settled.contains("One renamed"))

        let reloaded = LibraryStore(directory: directory)
        #expect(reloaded.orderedSpaces.map(\.name) == ["One renamed", "Two"])
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "myBrowser-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
