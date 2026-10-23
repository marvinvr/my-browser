import Foundation
import Testing
@testable import myBrowser

@MainActor
struct ImporterTests {
    @Test func chromiumKeepsBarFolderAndDropsJunk() throws {
        let plan = try chromiumPlan(bookmarkBarAsFolder: true)
        let space = try #require(plan.spaces.first)
        #expect(space.name == "Work")
        #expect(space.profileKey == "chromium")
        #expect(outline(space.pinned) == [
            "Bookmarks Bar [News https://example.com/news | Work [Docs https://example.com/docs | Nested [Spec https://example.com/spec]]]",
            "Other Bookmarks [Also news https://example.com/news | Notes https://example.com/notes]",
            "Mobile Bookmarks [Phone https://example.com/phone]",
        ])
        #expect(plan.pinnedSiteCount == 6)
        #expect(plan.pinnedFolderCount == 5)
    }

    @Test func chromiumCanHoistTheBookmarksBar() throws {
        let plan = try chromiumPlan(bookmarkBarAsFolder: false)
        let pinned = try #require(plan.spaces.first).pinned
        #expect(outline(pinned) == [
            "News https://example.com/news",
            "Work [Docs https://example.com/docs | Nested [Spec https://example.com/spec]]",
            "Other Bookmarks [Also news https://example.com/news | Notes https://example.com/notes]",
            "Mobile Bookmarks [Phone https://example.com/phone]",
        ])
    }

    @Test func chromiumSkipsEmptyRoots() throws {
        let json = """
        {"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"Only","url":"https://example.com/only"}]},"other":{"type":"folder","children":[]},"synced":{"type":"folder","children":[{"type":"folder","name":"Empty","children":[]}]}}}
        """
        let plan = try #require(ChromiumBookmarkParser.plan(
            data: Data(json.utf8),
            options: ChromiumBookmarkParser.Options(spaceName: "Solo")
        ))
        #expect(outline(plan.spaces.first?.pinned ?? []) == [
            "Bookmarks Bar [Only https://example.com/only]",
        ])
    }

    @Test func arcImportsSpacesProfilesAndFavorites() throws {
        let read = try arcRead(includeUnpinned: false)
        let plan = read.plan
        #expect(read.unpinnedSiteCount == 3)
        #expect(plan.spaces.map(\.name) == ["Personal", "Studio", "Notes"])
        #expect(plan.profiles.map(\.key) == ["default", "custom:Profile 1"])
        #expect(plan.profiles.map(\.name) == ["Default", "Profile 1"])
        #expect(plan.notes == ["Arc favorites were added to every space of each profile."])

        let personal = plan.spaces[0]
        #expect(personal.emoji == "🏠")
        #expect(personal.symbol == "house.fill")
        #expect(personal.color == .blue)
        #expect(outline(personal.favorites) == [
            "Mail https://example.com/mail",
            "Calendar https://example.com/calendar",
        ])
        #expect(outline(personal.pinned) == [
            "Projects [Docs https://example.com/docs | Specs [Spec https://example.com/spec]]",
            "News https://example.com/news",
        ])
        #expect(personal.tabs.isEmpty)

        let studio = plan.spaces[1]
        #expect(studio.emoji == nil)
        #expect(studio.symbol == "link")
        #expect(studio.color == .pink)
        #expect(studio.profileKey == plan.spaces[2].profileKey)
        #expect(outline(studio.favorites) == ["Board https://example.com/board-fav"])
        #expect(outline(studio.pinned) == ["Studio home https://example.com/studio"])

        let notes = plan.spaces[2]
        #expect(notes.emoji == "📚")
        #expect(notes.symbol == "book.fill")
        #expect(notes.color == .yellow)
        #expect(outline(notes.favorites) == outline(studio.favorites))
        #expect(outline(notes.pinned) == ["Note https://example.com/note"])
        #expect(notes.tabs.isEmpty)
    }

    @Test func arcCanIncludeUnpinnedTabs() throws {
        let plan = try arcRead(includeUnpinned: true).plan
        #expect(outline(plan.spaces[0].tabs) == ["Today https://example.com/today"])
        #expect(plan.spaces[1].tabs.isEmpty)
        #expect(outline(plan.spaces[2].tabs) == [
            "Draft https://example.com/draft",
            "Loose tab https://example.com/loose",
        ])
    }

    @Test func arcUsesProfileDisplayNamesAndSymbolNames() throws {
        let json = """
        {"sidebar":{"containers":[{"spaces":["s",{"id":"s","title":"Code","profile":{"custom":{"directoryBasename":"Default"}},"containerIDs":[],"customInfo":{"iconType":{"symbol":"hammer.fill"}}}],"items":[]}]}}
        """
        let read = try #require(ArcSidebarParser.read(
            data: Data(json.utf8),
            includeUnpinned: false,
            profileNames: ["Default": "Ada"]
        ))
        #expect(read.plan.profiles.first?.name == "Ada")
        #expect(read.plan.spaces.first?.symbol == "hammer.fill")
    }

    @Test func nearestSpaceColorMatchesHue() {
        #expect(SpaceColor.nearest(red: 0.56, green: 0.754, blue: 0.884) == .blue)
        #expect(SpaceColor.nearest(red: 0.95, green: 0.608, blue: 0.733) == .pink)
        #expect(SpaceColor.nearest(red: 0.823, green: 0.711, blue: 0.626) == .orange)
        #expect(SpaceColor.nearest(red: 0.95, green: 0.85, blue: 0.2) == .yellow)
        #expect(SpaceColor.nearest(red: 0.2, green: 0.7, blue: 0.7) == .teal)
        #expect(SpaceColor.nearest(red: 0.2, green: 0.75, blue: 0.3) == .green)
        #expect(SpaceColor.nearest(red: 0.6, green: 0.2, blue: 0.9) == .purple)
        #expect(SpaceColor.nearest(red: 0.9, green: 0.15, blue: 0.15) == .red)
        #expect(SpaceColor.nearest(red: 0.5, green: 0.5, blue: 0.52) == .gray)
    }

    @Test func applyCreatesSharedProfilesInOneBatch() throws {
        let plan = try arcRead(includeUnpinned: true).plan
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let existing = store.createSpace(name: "Personal")
        var batches: [Set<UUID>] = []
        store.onChange = { batches.append($0) }

        let result = store.apply(plan)
        #expect(batches.count == 1)
        #expect(result.spacesCreated == 3)
        #expect(result.profilesCreated == 2)
        #expect(result.summary == "Imported 3 spaces, 4 favorites, 7 pinned items, 3 tabs")
        #expect(store.orderedSpaces.map(\.id).first == existing.id)
        #expect(store.orderedSpaces.dropFirst().map(\.id) == result.spaceIDs)

        let personal = try #require(store.space(result.spaceIDs[0]))
        let studio = try #require(store.space(result.spaceIDs[1]))
        let notes = try #require(store.space(result.spaceIDs[2]))
        #expect(personal.emoji == "🏠")
        #expect(studio.profileID == notes.profileID)
        #expect(studio.profileID != personal.profileID)
        #expect(store.profile(studio.profileID)?.name == "Profile 1")
        let noteFavorites = store.children(of: nil, section: .favorites, in: notes.id)
        let studioFavorites = store.children(of: nil, section: .favorites, in: studio.id)
        #expect(noteFavorites.map(\.title) == ["Board"])
        #expect(studioFavorites.map(\.title) == ["Board"])
        #expect(noteFavorites.map(\.id) != studioFavorites.map(\.id))
        #expect(store.children(of: nil, section: .favorites, in: personal.id).map(\.title) == ["Mail", "Calendar"])

        let pinned = store.children(of: nil, section: .pinned, in: personal.id)
        #expect(pinned.map(\.title) == ["Projects", "News"])
        let projects = try #require(pinned.first)
        #expect(store.children(of: projects.id, section: .pinned, in: personal.id).map(\.title) == ["Docs", "Specs"])
        #expect(store.children(of: nil, section: .tabs, in: notes.id).map(\.title) == ["Draft", "Loose tab"])

        store.flush()
        let reloaded = LibraryStore(directory: directory)
        #expect(reloaded.space(personal.id)?.emoji == "🏠")
        #expect(reloaded.space(studio.id)?.emoji == nil)
        #expect(reloaded.space(studio.id)?.symbol == "link")
    }

    @Test func applyCanAppendIntoAnExistingSpace() throws {
        let plan = try chromiumPlan(bookmarkBarAsFolder: true)
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Already")
        var batches: [Set<UUID>] = []
        store.onChange = { batches.append($0) }

        let result = store.apply(plan, to: space.id)
        #expect(batches.count == 1)
        #expect(result.spacesCreated == 0)
        #expect(result.profilesCreated == 0)
        #expect(result.spaceIDs == [space.id])
        #expect(store.orderedSpaces.count == 1)
        #expect(store.profiles.count == 1)
        #expect(store.children(of: nil, section: .pinned, in: space.id).map(\.title) == [
            "Bookmarks Bar", "Other Bookmarks", "Mobile Bookmarks",
        ])
        #expect(result.summary == "Imported 11 pinned items")
    }

    @Test func missingEmojiDecodesFromAnOlderLibrary() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = UUID()
        let spaceID = UUID()
        let json = """
        {
          "items" : [],
          "profiles" : [
            { "id" : "\(profileID.uuidString)", "modifiedAt" : "2026-01-01T00:00:00Z", "name" : "Personal" }
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
              "symbol" : "person.fill"
            }
          ]
        }
        """
        let file = directory.appending(path: "library.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        let store = LibraryStore(directory: directory)
        let space = try #require(store.space(spaceID))
        #expect(space.emoji == nil)
        #expect(space.name == "Personal")
        #expect(space.symbol == "person.fill")
    }

    @Test func discoveryReadsProfileNamesAndSkipsEmptyProfiles() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appending(path: "Google/Chrome", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chrome.appending(path: "Default"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chrome.appending(path: "Profile 1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chrome.appending(path: "Profile 2"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chrome.appending(path: "Guest Profile"), withIntermediateDirectories: true)
        let bookmarks = try fixture("chrome-bookmarks.json")
        try bookmarks.write(to: chrome.appending(path: "Default/Bookmarks"))
        try bookmarks.write(to: chrome.appending(path: "Profile 1/Bookmarks"))
        try Data("{\"roots\":{}}".utf8).write(to: chrome.appending(path: "Profile 2/Bookmarks"))
        try bookmarks.write(to: chrome.appending(path: "Guest Profile/Bookmarks"))
        let localState = """
        {"profile":{"info_cache":{"Default":{"name":"Work","user_name":"hidden@example.com"},"Profile 1":{"name":"Play"},"Profile 2":{"name":"Empty"}}}}
        """
        try Data(localState.utf8).write(to: chrome.appending(path: "Local State"))

        let arc = root.appending(path: "Arc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        try fixture("arc-sidebar.json").write(to: arc.appending(path: "StorableSidebar.json"))

        let sources = ImportDiscovery.sources(in: root)
        #expect(sources.map(\.title) == ["Arc", "Chrome — Work", "Chrome — Play"])
        #expect(sources.first?.unpinnedSiteCount == 3)
        #expect(sources.map(\.kind) == [.arcSidebar, .chromium(.chrome), .chromium(.chrome)])
        #expect(!sources.contains { $0.detail.contains("hidden@example.com") })
    }

    @Test func onboardingTreatsAnExistingLibraryAsFinished() throws {
        let name = "onboarding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        Onboarding.prepareForLaunch(libraryDirectory: directory, defaults: defaults)
        #expect(defaults.bool(forKey: Onboarding.completedKey) == false)

        try Data("{}".utf8).write(to: directory.appending(path: "library.json"))
        Onboarding.prepareForLaunch(libraryDirectory: directory, defaults: defaults)
        #expect(defaults.bool(forKey: Onboarding.completedKey) == false)

        defaults.removeObject(forKey: Onboarding.completedKey)
        Onboarding.prepareForLaunch(libraryDirectory: directory, defaults: defaults)
        #expect(defaults.bool(forKey: Onboarding.completedKey) == true)
    }

    /// Opt-in. `xcodebuild` does not forward the shell environment, so a normal test run skips this.
    /// Counts only — never titles or URLs. The real sidebar is not a fixture and is not committed.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MYBROWSER_IMPORT_AUDIT"] == "1")
    )
    func auditRealArcSidebarCountsOnly() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = home.appending(path: "Library/Application Support/Arc/StorableSidebar.json")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        let data = try Data(contentsOf: file)
        let read = try #require(ArcSidebarParser.read(data: data, includeUnpinned: false))
        let plan = read.plan
        let lines = [
            "spaces \(plan.spaces.count)",
            "profiles \(plan.profiles.count)",
            "favorites \(plan.favoriteSiteCount)",
            "pinnedSites \(plan.pinnedSiteCount)",
            "pinnedFolders \(plan.pinnedFolderCount)",
            "unpinnedSites \(read.unpinnedSiteCount)",
        ]
        let output = URL(fileURLWithPath: "/tmp/mybrowser-import-audit.txt")
        try lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        #expect(plan.spaces.count > 0)
    }
}

private func chromiumPlan(bookmarkBarAsFolder: Bool) throws -> ImportPlan {
    let data = try fixture("chrome-bookmarks.json")
    return try #require(ChromiumBookmarkParser.plan(
        data: data,
        options: ChromiumBookmarkParser.Options(spaceName: "Work", bookmarkBarAsFolder: bookmarkBarAsFolder)
    ))
}

private func arcRead(includeUnpinned: Bool) throws -> ArcSidebarParser.Read {
    try #require(ArcSidebarParser.read(data: try fixture("arc-sidebar.json"), includeUnpinned: includeUnpinned))
}

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name)")
    return try Data(contentsOf: url)
}

private func outline(_ nodes: [ImportNode]) -> [String] {
    nodes.map { node in
        switch node {
        case .site(let title, let url):
            "\(title) \(url.absoluteString)"
        case .folder(let title, let children):
            "\(title) [\(outline(children).joined(separator: " | "))]"
        }
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "myBrowser-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
