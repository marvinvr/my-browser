import Foundation
import Testing
@testable import myBrowser

@MainActor
struct SessionStoreTests {
    @Test func nilDirectoryCapsClosedTabsWithoutDisk() {
        let store = SessionStore(directory: nil)
        store.closedTabs = (0..<60).map { closedTab(title: "\($0)") }
        store.flush()
        #expect(store.closedTabs.count == SessionStore.closedTabLimit)
        #expect(store.closedTabs.first?.item.title == "10")
        #expect(store.closedTabs.last?.item.title == "59")
    }

    @Test func pruneDropsInteractionStatesThatAreGone() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let keep = UUID()
        let drop = UUID()
        store.interactionStates = [keep: Data([1]), drop: Data([2, 3])]
        store.prune(keeping: [keep, UUID()])
        #expect(store.interactionStates[keep] == Data([1]))
        #expect(store.interactionStates[drop] == nil)

        store.prune(keeping: [keep])
        store.flush()
        let reloaded = SessionStore(directory: directory)
        #expect(reloaded.interactionStates == [keep: Data([1])])
    }

    @Test func roundTripAndClosedTabCap() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")
        let store = SessionStore(directory: directory)
        let spaceID = UUID()
        let itemID = UUID()
        let otherSpace = UUID()
        store.selectedSpaceID = spaceID
        store.selectedItemBySpace = [spaceID: itemID, otherSpace: UUID()]
        store.isSidebarVisible = false
        store.interactionStates = [itemID: Data([9, 8, 7])]
        let closed = (0..<60).map { index in
            closedTab(title: "\(index)", interactionState: index == 59 ? Data([4]) : nil)
        }
        let newestSpace = closed[59].item.spaceID
        store.closedTabs = closed
        #expect(store.closedTabs.count == 50)
        store.flush()

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"isSidebarVisible\" : false"))
        let closedKey = try #require(text.range(of: "\"closedTabs\""))
        let schemaKey = try #require(text.range(of: "\"schemaVersion\""))
        #expect(closedKey.lowerBound < schemaKey.lowerBound)

        let reloaded = SessionStore(directory: directory)
        #expect(reloaded.selectedSpaceID == spaceID)
        #expect(reloaded.selectedItemBySpace[spaceID] == itemID)
        #expect(reloaded.selectedItemBySpace.count == 2)
        #expect(reloaded.isSidebarVisible == false)
        #expect(reloaded.interactionStates[itemID] == Data([9, 8, 7]))
        #expect(reloaded.closedTabs.count == 50)
        #expect(reloaded.closedTabs.first?.item.title == "10")
        #expect(reloaded.closedTabs.last?.item.title == "59")
        #expect(reloaded.closedTabs.last?.interactionState == Data([4]))
        #expect(reloaded.closedTabs.last?.item.spaceID == newestSpace)
    }

    @Test func missingAndCorruptSessionFiles() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")

        let missing = SessionStore(directory: directory)
        #expect(missing.selectedSpaceID == nil)
        #expect(missing.isSidebarVisible == true)
        #expect(missing.closedTabs.isEmpty)

        try "nope".write(to: file, atomically: true, encoding: .utf8)
        let corrupt = SessionStore(directory: directory)
        #expect(corrupt.closedTabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("session.corrupt-") && $0.hasSuffix(".json") })
    }

    @Test func debouncedSaveAndFlush() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")
        let store = SessionStore(directory: directory)
        let spaceID = UUID()

        store.selectedSpaceID = spaceID
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        store.flush()
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))

        store.isSidebarVisible = false
        let beforeDebounce = try String(contentsOf: file, encoding: .utf8)
        #expect(beforeDebounce.contains("\"isSidebarVisible\" : true"))
        try await Task.sleep(for: .milliseconds(1200))
        let afterDebounce = try String(contentsOf: file, encoding: .utf8)
        #expect(afterDebounce.contains("\"isSidebarVisible\" : false"))

        let reloaded = SessionStore(directory: directory)
        #expect(reloaded.selectedSpaceID == spaceID)
        #expect(reloaded.isSidebarVisible == false)
    }
}

private func closedTab(title: String, interactionState: Data? = nil) -> SessionStore.ClosedTab {
    let spaceID = UUID()
    let item = SidebarItem(
        spaceID: spaceID,
        section: .tabs,
        kind: .site,
        title: title,
        url: URL(string: "https://example.com/\(title)"),
        sortKey: "a0"
    )
    return SessionStore.ClosedTab(item: item, interactionState: interactionState)
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "myBrowser-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
