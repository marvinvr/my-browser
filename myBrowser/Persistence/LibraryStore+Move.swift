import Foundation

extension LibraryStore {
    /// Whether `id` may land in `section` of `spaceID` under `parentID`.
    ///
    /// Favorites and tabs take sites only, and only at the root. A folder cannot move into
    /// itself or one of its descendants. `parentID` is only valid for a live folder in the
    /// destination space's pinned section.
    func canDrop(_ id: UUID, toSpace spaceID: UUID, section: SidebarItem.Section, parentID: UUID?) -> Bool {
        guard let moving = item(id), space(spaceID) != nil else { return false }
        if section != .pinned {
            return !moving.isFolder && parentID == nil
        }
        guard let parentID else { return true }
        if parentID == id { return false }
        guard let parent = item(parentID),
              parent.isFolder,
              parent.spaceID == spaceID,
              parent.section == .pinned else { return false }
        if !moving.isFolder { return true }
        return !descendantIDs(of: id, spaceID: moving.spaceID).contains(parentID)
    }

    /// Section used when an item is dropped on a space icon. Sites keep their section.
    /// Folders can only live in pinned, so that is where they go.
    func sectionForSpaceDrop(_ item: SidebarItem) -> SidebarItem.Section {
        item.isFolder ? .pinned : item.section
    }

    /// Moves `id` (and, for a folder, its live descendants) to another space, section, or slot.
    ///
    /// Descendants keep their parent links. Their `spaceID` and `section` change with the folder.
    /// One batch: a single `onChange` and one scheduled save. Rejected drops change nothing.
    func move(
        _ id: UUID,
        toSpace spaceID: UUID,
        section: SidebarItem.Section,
        parentID: UUID? = nil,
        position: Position = .end
    ) {
        guard let moving = item(id), canDrop(id, toSpace: spaceID, section: section, parentID: parentID) else { return }
        if case .before(let other) = position, other == id { return }
        if case .after(let other) = position, other == id { return }

        let resolvedParent = section == .pinned ? parentID : nil
        let descendants = moving.isFolder
            ? descendantIDs(of: id, spaceID: moving.spaceID).filter { items[$0]?.deletedAt == nil }
            : []

        performBatch {
            let key = sortKey(
                for: position,
                parentID: resolvedParent,
                section: section,
                spaceID: spaceID,
                excluding: id
            )
            updateItem(id) {
                $0.spaceID = spaceID
                $0.section = section
                $0.parentID = resolvedParent
                $0.sortKey = key
            }
            guard moving.isFolder else { return }
            for descendant in descendants {
                updateItem(descendant) {
                    $0.spaceID = spaceID
                    $0.section = section
                }
            }
        }
    }
}
