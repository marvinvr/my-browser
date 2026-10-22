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

    /// `nil` = in-memory only (tests, previews).
    let directory: URL?

    init(directory: URL?) {
        self.directory = directory
        // TODO(worker A): load library.json from `directory`.
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
        didChange()
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
        didChange()
    }

    /// Tombstones the space and all its items. TODO(worker A): also tombstone its profile if unused.
    func deleteSpace(_ id: UUID) {
        updateSpace(id) { $0.deletedAt = .now }
        for item in items.values where item.spaceID == id { deleteItem(item.id) }
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
        didChange()
        return item
    }

    func updateItem(_ id: UUID, _ mutate: (inout SidebarItem) -> Void) {
        guard var item = items[id] else { return }
        mutate(&item)
        item.modifiedAt = .now
        items[id] = item
        didChange()
    }

    /// Moves an item (and its subtree) to another section / folder / position within its space.
    func moveItem(_ id: UUID, to section: SidebarItem.Section, parentID: UUID? = nil, at position: Position = .end) {
        guard let item = items[id] else { return }
        let key = sortKey(for: position, parentID: parentID, section: section, spaceID: item.spaceID, excluding: id)
        updateItem(id) {
            $0.section = section
            $0.parentID = parentID
            $0.sortKey = key
        }
        // TODO(worker A): move descendants' section along with a folder.
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
        didChange()
        return restored
    }

    /// Synced items get a tombstone (folders: recursively); `.tabs` items are removed.
    func deleteItem(_ id: UUID) {
        guard let item = items[id] else { return }
        if item.isSynced {
            for child in items.values where child.parentID == id { deleteItem(child.id) }
            updateItem(id) { $0.deletedAt = .now }
        } else {
            items[id] = nil
            didChange()
        }
    }

    /// Writes pending changes to disk immediately (app termination).
    func flush() {
        // TODO(worker A)
    }

    // MARK: Private

    private func sortKey(for position: Position, parentID: UUID?, section: SidebarItem.Section, spaceID: UUID, excluding: UUID? = nil) -> String {
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

    private func didChange() {
        // TODO(worker A): schedule a debounced atomic save.
    }
}
