import CloudKit
import Foundation
import Testing
@testable import myBrowser

@MainActor
struct SyncTests {
    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private let newer = Date(timeIntervalSince1970: 1_700_000_100)

    @Test func recordMapperRoundTripsEveryField() throws {
        let profileID = UUID()
        let spaceID = UUID()
        let parentID = UUID()
        let itemID = UUID()
        var profile = Profile(id: profileID, name: "Work", modifiedAt: older)
        profile.deletedAt = newer
        var space = Space(
            id: spaceID,
            name: "Work",
            symbol: "briefcase.fill",
            emoji: "📁",
            color: .orange,
            profileID: profileID,
            sortKey: "M",
            modifiedAt: older
        )
        space.deletedAt = newer
        var item = SidebarItem(
            id: itemID,
            spaceID: spaceID,
            section: .pinned,
            kind: .folder,
            parentID: parentID,
            title: "Projects",
            url: URL(string: "https://example.com/docs?q=1#top"),
            sortKey: "B",
            isExpanded: false,
            createdAt: older
        )
        item.modifiedAt = newer
        item.deletedAt = newer

        let profileRecord = RecordMapper.record(for: profile)
        let spaceRecord = RecordMapper.record(for: space)
        let itemRecord = try #require(RecordMapper.record(for: item))

        #expect(profileRecord.recordType == SyncSchema.RecordType.profile)
        #expect(profileRecord.recordID.recordName == profileID.uuidString)
        #expect(profileRecord.recordID.zoneID.zoneName == SyncSchema.zoneName)
        #expect(RecordMapper.profile(from: profileRecord) == profile)
        #expect(spaceRecord.recordType == SyncSchema.RecordType.space)
        #expect(RecordMapper.space(from: spaceRecord) == space)
        #expect(itemRecord.recordType == SyncSchema.RecordType.sidebarItem)
        #expect(RecordMapper.item(from: itemRecord) == item)
        #expect(RecordMapper.decode(profileRecord) == .profile(profile))
        #expect(RecordMapper.decode(itemRecord) == .item(item))
    }

    @Test func recordMapperRoundTripsNilOptionalsAndRejectsTabs() {
        let profile = Profile(id: UUID(), name: "Personal", modifiedAt: older)
        let space = Space(
            id: UUID(),
            name: "Personal",
            symbol: "circle.fill",
            color: .teal,
            profileID: profile.id,
            sortKey: "A",
            modifiedAt: older
        )
        let item = SidebarItem(
            id: UUID(),
            spaceID: space.id,
            section: .favorites,
            kind: .site,
            title: "Example",
            sortKey: "A",
            isExpanded: true,
            createdAt: older
        )
        let tab = SidebarItem(
            id: UUID(),
            spaceID: space.id,
            section: .tabs,
            kind: .site,
            title: "Tab",
            url: URL(string: "https://example.com"),
            sortKey: "A",
            createdAt: older
        )

        #expect(RecordMapper.profile(from: RecordMapper.record(for: profile)) == profile)
        #expect(RecordMapper.profile(from: RecordMapper.record(for: profile))?.deletedAt == nil)
        #expect(RecordMapper.space(from: RecordMapper.record(for: space)) == space)
        let decodedItem = RecordMapper.record(for: item).flatMap(RecordMapper.item(from:))
        #expect(decodedItem == item)
        #expect(decodedItem?.parentID == nil)
        #expect(decodedItem?.url == nil)
        #expect(decodedItem?.deletedAt == nil)
        #expect(decodedItem?.isExpanded == true)
        #expect(RecordMapper.record(for: tab) == nil)

        var withEmoji = space
        withEmoji.emoji = "📁"
        let emojiRecord = RecordMapper.record(for: withEmoji)
        let emojiFields = RecordSystemFields.encode(emojiRecord)
        withEmoji.emoji = "   "
        let clearedEmoji = RecordMapper.record(for: withEmoji, systemFields: emojiFields)
        #expect(clearedEmoji[RecordMapper.Field.emoji] == nil)
        #expect(clearedEmoji.changedKeys().contains(RecordMapper.Field.emoji))
        #expect(RecordMapper.space(from: clearedEmoji)?.emoji == nil)

        let tabRecord = RecordMapper.record(for: item)
        tabRecord?[RecordMapper.Field.section] = SidebarItem.Section.tabs.rawValue
        #expect(tabRecord.flatMap(RecordMapper.item(from:)) == nil)
        #expect(RecordMapper.profile(from: CKRecord(recordType: "Other")) == nil)
    }

    @Test func systemFieldsKeepTheRecordIdentity() {
        let profile = Profile(id: UUID(), name: "Work", modifiedAt: older)
        let original = RecordMapper.record(for: profile)
        let data = RecordSystemFields.encode(original)
        let shell = RecordSystemFields.decode(data)
        #expect(shell?.recordID.recordName == original.recordID.recordName)
        #expect(shell?.recordType == original.recordType)
        #expect(shell?[RecordMapper.Field.name] == nil)

        let rebuilt = RecordMapper.record(for: profile, systemFields: data)
        #expect(rebuilt.recordID.recordName == profile.id.uuidString)
        #expect(rebuilt[RecordMapper.Field.name] as? String == "Work")
        #expect(RecordMapper.profile(from: rebuilt) == profile)
        #expect(RecordSystemFields.decode(Data()) == nil)
    }

    @Test func lastWriterWins() {
        let live = { (date: Date) in SyncConflict.Side(modifiedAt: date, deletedAt: nil) }
        let tombstone = { (date: Date) in SyncConflict.Side(modifiedAt: date, deletedAt: date) }

        #expect(SyncConflict.resolve(local: live(newer), server: live(older)) == .local)
        #expect(SyncConflict.resolve(local: live(older), server: live(newer)) == .server)
        #expect(SyncConflict.resolve(local: live(older), server: live(older)) == .server)

        #expect(SyncConflict.resolve(local: tombstone(newer), server: live(older)) == .local)
        #expect(SyncConflict.resolve(local: live(older), server: tombstone(newer)) == .server)
        #expect(SyncConflict.resolve(local: live(newer), server: tombstone(older)) == .local)
        #expect(SyncConflict.resolve(local: tombstone(older), server: live(newer)) == .server)
        #expect(SyncConflict.resolve(local: tombstone(older), server: live(older)) == .local)
        #expect(SyncConflict.resolve(local: live(older), server: tombstone(older)) == .server)
        #expect(SyncConflict.resolve(local: tombstone(older), server: tombstone(older)) == .server)

        let skewed = SyncConflict.Side(modifiedAt: older, deletedAt: newer)
        #expect(skewed.stamp == newer)
        #expect(SyncConflict.resolve(local: skewed, server: live(older)) == .local)

        #expect(SyncConflict.merge(local: nil, server: live(older)) == .applyServer)
        #expect(SyncConflict.merge(local: live(newer), server: live(older)) == .uploadLocal)
        #expect(SyncConflict.merge(local: live(older), server: live(newer)) == .applyServer)
    }

    @Test func missingServerRecordPrefersANewerLocalEdit() {
        let edit = SyncConflict.Side(modifiedAt: newer, deletedAt: nil)
        let oldEdit = SyncConflict.Side(modifiedAt: older, deletedAt: nil)
        let tombstone = SyncConflict.Side(modifiedAt: newer, deletedAt: newer)
        #expect(SyncConflict.resolveMissingServerRecord(local: nil, lastKnownServerModification: older) == .dropLocal)
        #expect(SyncConflict.resolveMissingServerRecord(local: edit, lastKnownServerModification: older) == .recreateLocal)
        #expect(SyncConflict.resolveMissingServerRecord(local: oldEdit, lastKnownServerModification: newer) == .dropLocal)
        #expect(SyncConflict.resolveMissingServerRecord(local: edit, lastKnownServerModification: nil) == .dropLocal)
        #expect(SyncConflict.resolveMissingServerRecord(local: tombstone, lastKnownServerModification: older) == .deletionAlreadyDone)
    }

    @Test func applyRemoteDoesNotEchoOrRewriteStamps() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        var echoes: [Set<UUID>] = []
        store.onChange = { echoes.append($0) }

        let profile = Profile(id: UUID(), name: "Remote", modifiedAt: older)
        var item = SidebarItem(
            id: UUID(),
            spaceID: UUID(),
            section: .pinned,
            kind: .site,
            title: "Remote pin",
            url: URL(string: "https://example.com"),
            sortKey: SortKey.between(nil, nil),
            createdAt: older
        )
        item.modifiedAt = older
        let tab = SidebarItem(
            id: UUID(),
            spaceID: item.spaceID,
            section: .tabs,
            kind: .site,
            title: "Local tab",
            sortKey: "A",
            createdAt: older
        )
        store.applyRemote(
            upserts: RemoteLibraryUpdate(profiles: [profile], items: [item, tab]),
            deletions: []
        )

        #expect(echoes.isEmpty)
        #expect(store.profiles[profile.id]?.modifiedAt == older)
        #expect(store.profiles[profile.id]?.name == "Remote")
        #expect(store.items[item.id]?.modifiedAt == older)
        #expect(store.items[tab.id] == nil)

        store.applyRemote(upserts: RemoteLibraryUpdate(), deletions: [profile.id, tab.id])
        #expect(echoes.isEmpty)
        #expect(store.profiles[profile.id] == nil)

        let local = store.addItem(spaceID: item.spaceID, section: .pinned, title: "Local")
        #expect(echoes.count == 1)
        #expect(echoes.last == [local.id])

        store.flush()
        let reloaded = LibraryStore(directory: directory)
        #expect(reloaded.profiles[profile.id] == nil)
        #expect(reloaded.items[item.id]?.title == "Remote pin")
        #expect(reloaded.items[item.id]?.modifiedAt == older)
        #expect(reloaded.item(local.id)?.title == "Local")
    }

    @Test func applyRemoteReplacesInvalidSortKeys() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let kept = store.addItem(spaceID: space.id, section: .pinned, title: "Kept", url: URL(string: "https://example.com"))
        let badSpace = Space(
            name: "Remote",
            symbol: "circle.fill",
            color: .blue,
            profileID: space.profileID,
            sortKey: "nope",
            modifiedAt: older
        )
        var first = SidebarItem(
            spaceID: space.id,
            section: .pinned,
            kind: .site,
            title: "Bad",
            url: URL(string: "https://example.com/a"),
            sortKey: "M",
            createdAt: older
        )
        first.modifiedAt = older
        var second = SidebarItem(
            spaceID: space.id,
            section: .pinned,
            kind: .site,
            title: "Also bad",
            url: URL(string: "https://example.com/b"),
            sortKey: "!!!",
            createdAt: older
        )
        second.modifiedAt = older
        let otherSection = SidebarItem(
            spaceID: space.id,
            section: .favorites,
            kind: .site,
            title: "Favorite",
            url: URL(string: "https://example.com/c"),
            sortKey: "M",
            createdAt: older
        )
        let tab = SidebarItem(
            spaceID: space.id,
            section: .tabs,
            kind: .site,
            title: "Tab",
            sortKey: "M",
            createdAt: older
        )

        store.applyRemote(
            upserts: RemoteLibraryUpdate(spaces: [badSpace], items: [first, second, otherSection, tab]),
            deletions: []
        )

        let storedSpace = store.spaces[badSpace.id]
        #expect(SortKey.isValid(storedSpace?.sortKey ?? ""))
        #expect((storedSpace?.sortKey ?? "") > space.sortKey)
        #expect(storedSpace?.modifiedAt == older)

        let storedFirst = store.items[first.id]
        let storedSecond = store.items[second.id]
        #expect(SortKey.isValid(storedFirst?.sortKey ?? ""))
        #expect(SortKey.isValid(storedSecond?.sortKey ?? ""))
        #expect((storedFirst?.sortKey ?? "") > kept.sortKey)
        #expect((storedSecond?.sortKey ?? "") > (storedFirst?.sortKey ?? ""))
        #expect(storedFirst?.modifiedAt == older)
        #expect(store.items[otherSection.id]?.sortKey == SortKey.between(nil, nil))
        #expect(store.items[tab.id] == nil)
        #expect(store.items[kept.id]?.sortKey == kept.sortKey)

        let inserted = store.addItem(spaceID: space.id, section: .pinned, title: "After")
        #expect(SortKey.isValid(inserted.sortKey))
        #expect(inserted.sortKey > (storedSecond?.sortKey ?? ""))
    }

    @Test func pendingChangesSkipTabsAndEmitTombstones() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let pin = store.addItem(spaceID: space.id, section: .pinned, title: "Pin", url: URL(string: "https://example.com"))
        let favorite = store.addItem(spaceID: space.id, section: .favorites, title: "Fav", url: URL(string: "https://example.com/fav"))
        let tab = store.addItem(spaceID: space.id, section: .tabs, title: "Tab")

        let pending = store.pendingChanges(for: [space.id, space.profileID, pin.id, favorite.id, tab.id])
        #expect(pending.contains(.save(space.id)))
        #expect(pending.contains(.save(space.profileID)))
        #expect(pending.contains(.save(pin.id)))
        #expect(pending.contains(.save(favorite.id)))
        #expect(!pending.contains(.save(tab.id)))
        #expect(!pending.contains(.delete(tab.id)))

        store.deleteItem(pin.id)
        store.deleteItem(tab.id)
        #expect(store.pendingChanges(for: [pin.id]) == [.delete(pin.id)])
        #expect(store.pendingChanges(for: [tab.id]).isEmpty)
        #expect(store.pendingChanges(for: [UUID()]).isEmpty)

        let ids = store.pendingChanges(for: [favorite.id, pin.id]).map(\.id.uuidString)
        #expect(ids == ids.sorted())
    }

    @Test func purgeWaitsUntilTheDeletionWasSent() {
        let store = LibraryStore(directory: nil)
        var echoes: [Set<UUID>] = []
        store.onChange = { echoes.append($0) }
        let space = store.createSpace(name: "Personal")
        let oldPin = store.addItem(spaceID: space.id, section: .pinned, title: "Old")
        let youngPin = store.addItem(spaceID: space.id, section: .pinned, title: "Young")
        let live = store.addItem(spaceID: space.id, section: .favorites, title: "Live", url: URL(string: "https://example.com"))
        store.deleteItem(oldPin.id)
        store.deleteItem(youngPin.id)
        store.updateItem(oldPin.id) { $0.deletedAt = older }
        echoes.removeAll()

        let cutoff = newer
        #expect(store.purgeAcknowledgedTombstones(sent: [], olderThan: cutoff).isEmpty)
        #expect(store.items[oldPin.id]?.deletedAt != nil)

        let unsent = store.purgeAcknowledgedTombstones(sent: [live.id], olderThan: cutoff)
        #expect(unsent.isEmpty)
        #expect(store.item(live.id)?.title == "Live")

        let young = store.purgeAcknowledgedTombstones(sent: [youngPin.id], olderThan: older)
        #expect(young.isEmpty)
        #expect(store.items[youngPin.id]?.deletedAt != nil)

        let purged = store.purgeAcknowledgedTombstones(sent: [oldPin.id, youngPin.id], olderThan: cutoff)
        #expect(purged == [oldPin.id])
        #expect(store.items[oldPin.id] == nil)
        #expect(store.items[youngPin.id]?.deletedAt != nil)
        #expect(echoes.isEmpty)
    }

    @Test func equalSortKeysOrderByID() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let first = store.addItem(spaceID: space.id, section: .pinned, title: "One")
        let second = store.addItem(spaceID: space.id, section: .pinned, title: "Two")
        store.updateItem(first.id) { $0.sortKey = "M" }
        store.updateItem(second.id) { $0.sortKey = "M" }

        let ordered = store.children(of: nil, section: .pinned, in: space.id).map(\.id)
        let expected = [first.id, second.id].sorted { $0.uuidString < $1.uuidString }
        #expect(ordered == expected)
    }

    @Test func syncStateRoundTripsAndRejectsANewSchema() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let state = SyncState(directory: directory)
        state.setEngineState(Data([1, 2, 3, 4]))
        state.setSystemFields(Data([9, 9]), for: id)
        state.markDeletionSent([id])
        state.setAwaitingAccountChoice(true)

        let loaded = SyncState(directory: directory)
        #expect(loaded.engineState == Data([1, 2, 3, 4]))
        #expect(loaded.systemFields(for: id) == Data([9, 9]))
        #expect(loaded.acknowledgedDeletions == [id])
        #expect(loaded.awaitingAccountChoice)

        loaded.removeSystemFields(for: id)
        loaded.removeAcknowledgedDeletions([id])
        loaded.setAwaitingAccountChoice(false)
        let cleared = SyncState(directory: directory)
        #expect(cleared.systemFields(for: id) == nil)
        #expect(cleared.acknowledgedDeletions.isEmpty)
        #expect(!cleared.awaitingAccountChoice)
        #expect(cleared.engineState == Data([1, 2, 3, 4]))

        cleared.reset()
        let reset = SyncState(directory: directory)
        #expect(reset.engineState == nil)
        #expect(reset.acknowledgedDeletions.isEmpty)

        let stale = directory.appending(path: SyncState.fileName)
        let body = """
        {
          "acknowledgedDeletions" : [],
          "awaitingAccountChoice" : false,
          "engineState" : null,
          "schemaVersion" : 2,
          "systemFields" : {}
        }
        """
        try Data(body.utf8).write(to: stale)
        let rejected = SyncState(directory: directory)
        #expect(rejected.engineState == nil)
        #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(names.contains { $0.contains("corrupt") })

        let memory = SyncState(directory: nil)
        memory.setEngineState(Data([7]))
        #expect(memory.engineState == Data([7]))
    }

    @Test func applyRemotePreservesSplitLayoutHomeURLAndFolderState() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let profileID = UUID()
        let spaceID = UUID()
        let folderID = UUID()
        let splitID = UUID()
        let memberID = UUID()
        let home = try #require(URL(string: "https://pin.example/home?q=1"))
        var folder = SidebarItem(
            id: folderID,
            spaceID: spaceID,
            section: .pinned,
            kind: .folder,
            title: "Work",
            sortKey: "a0",
            isExpanded: false,
            createdAt: older
        )
        folder.modifiedAt = older
        var split = SidebarItem(
            id: splitID,
            spaceID: spaceID,
            section: .pinned,
            kind: .split,
            parentID: folderID,
            title: "Pair",
            sortKey: "a1",
            splitAxis: .vertical,
            createdAt: older
        )
        split.modifiedAt = older
        var member = SidebarItem(
            id: memberID,
            spaceID: spaceID,
            section: .pinned,
            kind: .site,
            parentID: splitID,
            title: "Pin",
            url: home,
            sortKey: "b0",
            splitFraction: 0.35,
            createdAt: older
        )
        member.modifiedAt = older
        let sibling = SidebarItem(
            id: UUID(),
            spaceID: spaceID,
            section: .pinned,
            kind: .site,
            parentID: splitID,
            title: "Other",
            url: URL(string: "https://other.example"),
            sortKey: "b1",
            splitFraction: 0.65,
            createdAt: older
        )
        var stampedSibling = sibling
        stampedSibling.modifiedAt = older

        let folderRecord = try #require(RecordMapper.record(for: folder))
        let splitRecord = try #require(RecordMapper.record(for: split))
        let memberRecord = try #require(RecordMapper.record(for: member))
        let siblingRecord = try #require(RecordMapper.record(for: stampedSibling))
        store.applyRemote(
            upserts: RemoteLibraryUpdate(
                profiles: [Profile(id: profileID, name: "Work", modifiedAt: older)],
                spaces: [Space(id: spaceID, name: "Work", symbol: "circle.fill", color: .blue, profileID: profileID, sortKey: "a0", modifiedAt: older)],
                items: [
                    try #require(RecordMapper.item(from: folderRecord)),
                    try #require(RecordMapper.item(from: splitRecord)),
                    try #require(RecordMapper.item(from: memberRecord)),
                    try #require(RecordMapper.item(from: siblingRecord)),
                ]
            ),
            deletions: []
        )

        #expect(store.item(folderID)?.isExpanded == false)
        #expect(store.item(splitID)?.kind == .split)
        #expect(store.item(splitID)?.parentID == folderID)
        #expect(store.item(splitID)?.splitAxis == .vertical)
        #expect(store.item(memberID)?.parentID == splitID)
        #expect(store.item(memberID)?.splitFraction == 0.35)
        #expect(store.item(memberID)?.url == home)
        #expect(store.splitMembers(of: splitID).map(\.id) == [memberID, stampedSibling.id])
    }

    @Test func syncStartsOnlyWhenEveryGateIsOpen() {
        #expect(!SyncController.shouldStart(enabled: false, containerIdentifier: "iCloud.ch.marvinvr.mybrowser", hasAccount: true))
        #expect(!SyncController.shouldStart(enabled: true, containerIdentifier: nil, hasAccount: true))
        #expect(!SyncController.shouldStart(enabled: true, containerIdentifier: "  ", hasAccount: true))
        #expect(!SyncController.shouldStart(enabled: true, containerIdentifier: "iCloud.ch.marvinvr.mybrowser", hasAccount: false))
        #expect(SyncController.shouldStart(enabled: true, containerIdentifier: " iCloud.ch.marvinvr.mybrowser ", hasAccount: true))
        #expect(SyncController.containerInfoKey == "MBCloudKitContainer")
        #expect(SyncController.enabledDefaultsKey == "iCloudSyncEnabled")
    }

    @Test func untouchedPlaceholderIsDroppedWheniCloudAlreadyHasSpaces() {
        let store = LibraryStore(directory: nil)
        var echoes: [Set<UUID>] = []
        store.onChange = { echoes.append($0) }
        let placeholder = store.ensureDefaultSpace()
        let ids = store.untouchedPlaceholderIDs
        #expect(ids == [placeholder.id, placeholder.profileID])
        #expect(PlaceholderSync.afterFetch(placeholderIDs: ids, liveSpaceIDs: [placeholder.id]) == .upload(ids))

        let kept = store.createSpace(name: "Day Trip", symbol: "sun.max.fill", color: .orange)
        #expect(store.untouchedPlaceholderIDs.isEmpty)
        #expect(store.placeholderStillUntouched(ids))
        let live = Set(store.spaces.values.filter { $0.deletedAt == nil }.map(\.id))
        #expect(PlaceholderSync.afterFetch(placeholderIDs: ids, liveSpaceIDs: live) == .drop(ids))
        echoes.removeAll()
        let removed = store.discardPlaceholder(ids)
        #expect(removed == ids)
        #expect(store.space(placeholder.id) == nil)
        #expect(store.profile(placeholder.profileID) == nil)
        #expect(store.space(kept.id)?.name == "Day Trip")
        #expect(store.pendingChanges(for: ids).isEmpty)
        #expect(echoes.isEmpty)

        let renamed = LibraryStore(directory: nil)
        let personal = renamed.ensureDefaultSpace()
        renamed.updateSpace(personal.id) { $0.name = "Home" }
        #expect(renamed.untouchedPlaceholderIDs.isEmpty)

        let pinned = LibraryStore(directory: nil)
        let space = pinned.ensureDefaultSpace()
        _ = pinned.addItem(spaceID: space.id, section: .pinned, title: "Maps", url: URL(string: "https://example.com/maps"))
        #expect(pinned.untouchedPlaceholderIDs.isEmpty)

        let tabbed = LibraryStore(directory: nil)
        let home = tabbed.ensureDefaultSpace()
        _ = tabbed.addItem(spaceID: home.id, section: .tabs, title: "Local")
        #expect(tabbed.untouchedPlaceholderIDs == [home.id, home.profileID])

        let custom = LibraryStore(directory: nil)
        let circle = custom.createSpace(name: "Personal")
        #expect(custom.untouchedPlaceholderIDs.isEmpty)
        #expect(circle.symbol != "person.fill")
    }

    @Test func footerStaysPausedAndDoesNotIdleWhileChangesArePending() {
        #expect(SyncActivityStatus.text(paused: true, hasPendingChanges: false) == SyncController.pausedStatus)
        #expect(SyncActivityStatus.text(paused: true, hasPendingChanges: true) == SyncController.pausedStatus)
        #expect(SyncActivityStatus.text(paused: false, hasPendingChanges: true) == SyncController.syncingStatus)
        #expect(SyncActivityStatus.text(paused: false, hasPendingChanges: false) == SyncController.idleStatus)
    }
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mybrowser-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
