import Foundation
import Observation

/// Synced library: profiles, spaces, sidebar items. Single source of truth for the sidebar.
/// Mutations go through the methods below so `modifiedAt`, tombstones and saving stay consistent.
@Observable
final class LibraryStore {
    enum Position: Equatable {
        case start, end
        case before(UUID)
        case after(UUID)
    }

    private(set) var profiles: [UUID: Profile] = [:]
    private(set) var spaces: [UUID: Space] = [:]
    private(set) var items: [UUID: SidebarItem] = [:]

    /// `nil` = in-memory only (tests, previews). Never reads or writes disk.
    let directory: URL?

    /// Invoked with the ids of records each mutation changed. Not persisted (Phase 2 sync).
    @ObservationIgnored var onChange: ((Set<UUID>) -> Void)?

    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Non-nil while a mutation is collecting ids so callers see one `onChange` per action.
    @ObservationIgnored private var batchedChangeIDs: Set<UUID>?

    private static let schemaVersion = 1
    private static let saveDelay: Duration = .milliseconds(500)

    init(directory: URL?) {
        self.directory = directory
        if directory != nil {
            load()
        }
    }

    static func defaultDirectory() -> URL {
        URL.applicationSupportDirectory.appending(path: "myBrowser", directoryHint: .isDirectory)
    }

    // MARK: Queries (tombstones excluded)

    var orderedSpaces: [Space] {
        spaces.values.filter { $0.deletedAt == nil }.sorted { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
    }

    func space(_ id: UUID) -> Space? { spaces[id].flatMap { $0.deletedAt == nil ? $0 : nil } }
    func profile(_ id: UUID) -> Profile? { profiles[id].flatMap { $0.deletedAt == nil ? $0 : nil } }
    func item(_ id: UUID) -> SidebarItem? { items[id].flatMap { $0.deletedAt == nil ? $0 : nil } }

    /// Sorted children of `parentID` (nil = root) in one section of a space.
    func children(of parentID: UUID?, section: SidebarItem.Section, in spaceID: UUID) -> [SidebarItem] {
        items.values
            .filter { $0.deletedAt == nil && $0.spaceID == spaceID && $0.section == section && $0.parentID == parentID }
            .sorted { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
    }

    // MARK: Spaces

    /// Creates a space with its own new profile, appended at the end.
    @discardableResult
    func createSpace(name: String, symbol: String = "circle.fill", color: SpaceColor = .blue) -> Space {
        let profile = Profile(name: name)
        profiles[profile.id] = profile
        let space = Space(name: name, symbol: symbol, color: color, profileID: profile.id,
                          sortKey: SortKey.between(orderedSpaces.last?.sortKey, nil))
        spaces[space.id] = space
        didChange([profile.id, space.id])
        return space
    }

    /// Returns the first space, creating a default one ("Personal") if there is none.
    @discardableResult
    func ensureDefaultSpace() -> Space {
        if let first = orderedSpaces.first { return first }
        return createSpace(name: "Personal", symbol: "person.fill", color: .blue)
    }

    func updateSpace(_ id: UUID, _ mutate: (inout Space) -> Void) {
        guard var space = spaces[id] else { return }
        mutate(&space)
        space.modifiedAt = .now
        spaces[id] = space
        didChange([id])
    }

    /// Tombstones the space, its items, and its profile when no other live space uses that profile.
    func deleteSpace(_ id: UUID) {
        guard let profileID = spaces[id]?.profileID else { return }
        performBatch {
            updateSpace(id) { $0.deletedAt = .now }
            let spaceItemIDs = Set(items.values.filter { $0.spaceID == id }.map(\.id))
            let roots = spaceItemIDs.filter { itemID in
                guard let parentID = items[itemID]?.parentID else { return true }
                return !spaceItemIDs.contains(parentID)
            }
            for root in roots {
                deleteItem(root)
            }
            tombstoneProfileIfUnused(profileID)
        }
    }

    // MARK: Items

    @discardableResult
    func addItem(
        spaceID: UUID,
        section: SidebarItem.Section,
        kind: SidebarItem.Kind = .site,
        parentID: UUID? = nil,
        title: String,
        url: URL? = nil,
        at position: Position = .end
    ) -> SidebarItem {
        let key = sortKey(for: position, parentID: parentID, section: section, spaceID: spaceID)
        let item = SidebarItem(spaceID: spaceID, section: section, kind: kind, parentID: parentID,
                               title: title, url: url, sortKey: key)
        items[item.id] = item
        didChange([item.id])
        return item
    }

    func updateItem(_ id: UUID, _ mutate: (inout SidebarItem) -> Void) {
        guard var item = items[id] else { return }
        mutate(&item)
        item.modifiedAt = .now
        items[id] = item
        didChange([id])
    }

    /// Moves an item to another section, folder, or position within its space.
    /// A folder's descendants change section with it. Folders cannot move into `.favorites` or `.tabs` (those sections are flat sites); that call is ignored.
    func moveItem(_ id: UUID, to section: SidebarItem.Section, parentID: UUID? = nil, at position: Position = .end) {
        guard let item = items[id], item.deletedAt == nil else { return }
        if item.isFolder, section == .favorites || section == .tabs {
            return
        }
        let resolvedParent = section == .pinned ? parentID : nil
        performBatch {
            let key = sortKey(for: position, parentID: resolvedParent, section: section, spaceID: item.spaceID, excluding: id)
            let sectionChanged = item.section != section
            updateItem(id) {
                $0.section = section
                $0.parentID = resolvedParent
                $0.sortKey = key
            }
            guard item.isFolder, sectionChanged else { return }
            for descendant in descendantIDs(of: id, spaceID: item.spaceID) {
                updateItem(descendant) { $0.section = section }
            }
        }
    }

    /// Puts a hard-deleted `.tabs` item back (closed-tab reopen). The id is kept; the sort key is replaced.
    @discardableResult
    func restoreItem(_ item: SidebarItem, at position: Position = .start) -> SidebarItem {
        var restored = item
        restored.deletedAt = nil
        restored.section = .tabs
        restored.kind = .site
        restored.parentID = nil
        restored.sortKey = sortKey(for: position, parentID: nil, section: .tabs, spaceID: item.spaceID, excluding: item.id)
        restored.modifiedAt = .now
        items[restored.id] = restored
        didChange([restored.id])
        return restored
    }

    /// Synced items get a tombstone (folders: recursively); `.tabs` items are removed.
    func deleteItem(_ id: UUID) {
        guard items[id] != nil else { return }
        performBatch {
            var seen: Set<UUID> = []
            deleteItemSubtree(id, seen: &seen)
        }
    }

    /// Drops tombstoned profiles, spaces, and items deleted before `cutoff`.
    /// Defaults to 30 days ago. Not called automatically (Phase 2 purges once sync has acknowledged the deletion).
    func purgeTombstones(olderThan cutoff: Date = .now.addingTimeInterval(-30 * 24 * 60 * 60)) {
        let profileIDs = profiles.compactMap { id, profile -> UUID? in
            guard let deletedAt = profile.deletedAt, deletedAt < cutoff else { return nil }
            return id
        }
        let spaceIDs = spaces.compactMap { id, space -> UUID? in
            guard let deletedAt = space.deletedAt, deletedAt < cutoff else { return nil }
            return id
        }
        let itemIDs = items.compactMap { id, item -> UUID? in
            guard let deletedAt = item.deletedAt, deletedAt < cutoff else { return nil }
            return id
        }
        guard !profileIDs.isEmpty || !spaceIDs.isEmpty || !itemIDs.isEmpty else { return }
        for id in profileIDs { profiles[id] = nil }
        for id in spaceIDs { spaces[id] = nil }
        for id in itemIDs { items[id] = nil }
        didChange(Set(profileIDs + spaceIDs + itemIDs))
    }

    /// Writes pending changes to disk immediately (app termination). No-op when nothing changed, or when `directory` is nil.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        writeIfDirty()
    }

    // MARK: Private

    private func sortKey(for position: Position, parentID: UUID?, section: SidebarItem.Section, spaceID: UUID, excluding: UUID? = nil) -> String {
        renormalizeSiblings(parentID: parentID, section: section, spaceID: spaceID, excluding: excluding)
        let siblings = children(of: parentID, section: section, in: spaceID).filter { $0.id != excluding }
        switch position {
        case .start:
            return SortKey.between(nil, siblings.first?.sortKey)
        case .end:
            return SortKey.between(siblings.last?.sortKey, nil)
        case .before(let id):
            guard let index = siblings.firstIndex(where: { $0.id == id }) else { return SortKey.between(siblings.last?.sortKey, nil) }
            return SortKey.between(index > 0 ? siblings[index - 1].sortKey : nil, siblings[index].sortKey)
        case .after(let id):
            guard let index = siblings.firstIndex(where: { $0.id == id }) else { return SortKey.between(siblings.last?.sortKey, nil) }
            return SortKey.between(siblings[index].sortKey, index + 1 < siblings.count ? siblings[index + 1].sortKey : nil)
        }
    }

    /// Rewrites a sibling run whose keys collide or run backwards, in current display order.
    /// `children` stays a pure read; only this insert path mutates.
    private func renormalizeSiblings(parentID: UUID?, section: SidebarItem.Section, spaceID: UUID, excluding: UUID?) {
        let siblings = children(of: parentID, section: section, in: spaceID).filter { $0.id != excluding }
        let keys = siblings.map(\.sortKey)
        let strictlyIncreasing = zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }
        guard !strictlyIncreasing else { return }
        let fresh = SortKey.sequence(count: siblings.count)
        for (item, key) in zip(siblings, fresh) where item.sortKey != key {
            updateItem(item.id) { $0.sortKey = key }
        }
    }

    private func deleteItemSubtree(_ id: UUID, seen: inout Set<UUID>) {
        guard seen.insert(id).inserted, let item = items[id] else { return }
        if item.isSynced {
            let childIDs = items.values.filter { $0.parentID == id }.map(\.id)
            for childID in childIDs {
                deleteItemSubtree(childID, seen: &seen)
            }
            updateItem(id) { $0.deletedAt = .now }
        } else {
            items[id] = nil
            didChange([id])
        }
    }

    private func descendantIDs(of root: UUID, spaceID: UUID) -> [UUID] {
        var byParent: [UUID: [UUID]] = [:]
        for item in items.values where item.spaceID == spaceID {
            if let parentID = item.parentID {
                byParent[parentID, default: []].append(item.id)
            }
        }
        var result: [UUID] = []
        var queue = byParent[root] ?? []
        var seen: Set<UUID> = [root]
        var index = 0
        while index < queue.count {
            let id = queue[index]
            index += 1
            guard seen.insert(id).inserted else { continue }
            result.append(id)
            if let children = byParent[id] {
                queue.append(contentsOf: children)
            }
        }
        return result
    }

    private func tombstoneProfileIfUnused(_ profileID: UUID) {
        let inUse = spaces.values.contains { $0.deletedAt == nil && $0.profileID == profileID }
        guard !inUse, var profile = profiles[profileID], profile.deletedAt == nil else { return }
        profile.deletedAt = .now
        profile.modifiedAt = .now
        profiles[profileID] = profile
        didChange([profileID])
    }

    private func performBatch(_ body: () -> Void) {
        if batchedChangeIDs != nil {
            body()
            return
        }
        batchedChangeIDs = []
        body()
        let ids = batchedChangeIDs ?? []
        batchedChangeIDs = nil
        publish(ids)
    }

    private func didChange(_ ids: Set<UUID>) {
        if batchedChangeIDs != nil {
            batchedChangeIDs?.formUnion(ids)
            return
        }
        publish(ids)
    }

    private func publish(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        onChange?(ids)
        scheduleSave()
    }

    private func scheduleSave() {
        guard directory != nil else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self.writeIfDirty()
        }
    }

    private func writeIfDirty() {
        guard isDirty, let directory else { return }
        isDirty = false
        do {
            try JSONFileStorage.write(snapshot(), to: fileURL(in: directory))
        } catch {
            isDirty = true
        }
    }

    private func load() {
        guard let directory else { return }
        let url = fileURL(in: directory)
        do {
            guard let snapshot = try JSONFileStorage.read(LibrarySnapshot.self, from: url) else { return }
            guard snapshot.schemaVersion == Self.schemaVersion else {
                JSONFileStorage.quarantine(url)
                return
            }
            for profile in snapshot.profiles { profiles[profile.id] = profile }
            for space in snapshot.spaces { spaces[space.id] = space }
            for item in snapshot.items { items[item.id] = item }
        } catch {
            return
        }
    }

    private func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(
            schemaVersion: Self.schemaVersion,
            profiles: profiles.values.sorted { $0.id.uuidString < $1.id.uuidString },
            spaces: spaces.values.sorted { $0.id.uuidString < $1.id.uuidString },
            items: items.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    private func fileURL(in directory: URL) -> URL {
        directory.appending(path: "library.json", directoryHint: .notDirectory)
    }
}

nonisolated private struct LibrarySnapshot: Codable, Sendable {
    var schemaVersion: Int
    var profiles: [Profile]
    var spaces: [Space]
    var items: [SidebarItem]
}
