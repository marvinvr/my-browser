import Foundation

extension LibraryStore {
    /// Whether `id` may land in `section` of `spaceID` under `parentID`.
    ///
    /// Favorites take sites only, at the root. Tabs take sites and splits, at the root.
    /// A split cannot land in favorites or inside another split. A folder cannot move into
    /// itself or one of its descendants. `parentID` is only valid for a live folder in the
    /// destination space's pinned section.
    func canDrop(_ id: UUID, toSpace spaceID: UUID, section: SidebarItem.Section, parentID: UUID?) -> Bool {
        guard let moving = item(id), space(spaceID) != nil else { return false }
        if moving.isSplit {
            if section == .favorites { return false }
            if section != .pinned { return parentID == nil }
            guard let parentID else { return true }
            if parentID == id { return false }
            guard let parent = item(parentID),
                  parent.isFolder,
                  parent.spaceID == spaceID,
                  parent.section == .pinned else { return false }
            return !descendantIDs(of: id, spaceID: moving.spaceID).contains(parentID)
        }
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

    /// Moves `id` (and, for a folder or a split, its live descendants) to another space, section, or slot.
    ///
    /// Descendants keep their parent links. Their `spaceID` and `section` change with the folder
    /// or the split. A member dragged out of its split dissolves the split when one pane is left.
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
        let sourceSplit = splitContainer(of: id)?.id
        let carriesChildren = moving.isFolder || moving.isSplit
        let descendants = carriesChildren
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
                if let sourceSplit, resolvedParent != sourceSplit {
                    $0.splitFraction = nil
                }
            }
            if carriesChildren {
                for descendant in descendants {
                    updateItem(descendant) {
                        $0.spaceID = spaceID
                        $0.section = section
                    }
                }
            }
            if let sourceSplit, resolvedParent != sourceSplit {
                clearSplitFractions(sourceSplit)
                reconcileSplit(sourceSplit)
            }
        }
    }
}
