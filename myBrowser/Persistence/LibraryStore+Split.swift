import Foundation

extension LibraryStore {
    /// Live site panes of a split, left to right (top to bottom when the axis is vertical).
    /// Empty when `splitID` is not a live split.
    func splitMembers(of splitID: UUID) -> [SidebarItem] {
        guard let split = item(splitID), split.isSplit else { return [] }
        return children(of: splitID, section: split.section, in: split.spaceID).filter { $0.kind == .site }
    }

    /// The split that contains this site, if it is still live.
    func splitContainer(of itemID: UUID) -> SidebarItem? {
        guard let parentID = item(itemID)?.parentID, let parent = item(parentID), parent.isSplit else { return nil }
        return parent
    }

    /// Groups 2...4 sites from the same space into one split.
    ///
    /// The split takes the first site's section, folder (pinned only), and sort key.
    /// Every id must be a live site in that space, not a favorite, and not already in a split.
    /// Members are reparented in `tabIDs` order and share the anchor's section. Returns nil
    /// when the ids cannot form a split. An empty `axis` (and `.horizontal`) stores no axis.
    @discardableResult
    func createSplit(tabIDs: [UUID], axis: SidebarItem.SplitAxis? = nil) -> SidebarItem? {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []
        for id in tabIDs where seen.insert(id).inserted {
            ordered.append(id)
        }
        guard (SidebarItem.minimumSplitMembers...SidebarItem.maximumSplitMembers).contains(ordered.count) else { return nil }
        let sites = ordered.compactMap { item($0) }
        guard sites.count == ordered.count else { return nil }
        guard sites.allSatisfy({ $0.kind == .site }) else { return nil }
        guard sites.allSatisfy({ $0.section != .favorites }) else { return nil }
        guard sites.allSatisfy({ splitContainer(of: $0.id) == nil }) else { return nil }
        let anchor = sites[0]
        guard anchor.section == .pinned || anchor.section == .tabs else { return nil }
        guard sites.allSatisfy({ $0.spaceID == anchor.spaceID }) else { return nil }
        guard space(anchor.spaceID) != nil else { return nil }

        let parentID = splitParent(for: anchor)
        let storedAxis: SidebarItem.SplitAxis? = axis == .horizontal ? nil : axis
        var created: SidebarItem?
        performBatch {
            let split = SidebarItem(
                spaceID: anchor.spaceID,
                section: anchor.section,
                kind: .split,
                parentID: parentID,
                title: anchor.title,
                sortKey: anchor.sortKey,
                splitAxis: storedAxis
            )
            items[split.id] = split
            didChange([split.id])
            let keys = SortKey.sequence(count: sites.count)
            for (site, key) in zip(sites, keys) {
                updateItem(site.id) {
                    $0.spaceID = anchor.spaceID
                    $0.section = anchor.section
                    $0.parentID = split.id
                    $0.sortKey = key
                    $0.splitFraction = nil
                }
            }
            created = items[split.id]
        }
        return created
    }

    /// Inserts a loose site into a split at `index` (0 = leftmost). Out-of-range indexes clamp.
    ///
    /// Already-member sites are reordered instead. Returns nil when the split is missing,
    /// full (4), or the site is in another space, another split, or not a site. Adding a
    /// member clears every fraction back to equal widths.
    @discardableResult
    func addToSplit(tabID: UUID, splitID: UUID, at index: Int) -> SidebarItem? {
        guard let split = item(splitID), split.isSplit else { return nil }
        guard let tab = item(tabID), tab.kind == .site, tab.spaceID == split.spaceID else { return nil }
        if tab.parentID == splitID {
            movePane(tabID: tabID, to: index)
            return item(tabID)
        }
        if splitContainer(of: tabID) != nil { return nil }
        let members = splitMembers(of: splitID)
        guard members.count < SidebarItem.maximumSplitMembers else { return nil }
        let clamped = min(max(index, 0), members.count)
        performBatch {
            let position = insertionPosition(at: clamped, in: members)
            let key = sortKey(
                for: position,
                parentID: split.id,
                section: split.section,
                spaceID: split.spaceID,
                excluding: tabID
            )
            updateItem(tabID) {
                $0.spaceID = split.spaceID
                $0.section = split.section
                $0.parentID = split.id
                $0.sortKey = key
                $0.splitFraction = nil
            }
            clearSplitFractions(splitID)
        }
        return item(tabID)
    }

    /// Lifts a member out and places it immediately after the split, in the split's section.
    ///
    /// A split left with one member dissolves: that member takes the split's parent, section,
    /// and sort key. A pinned split is tombstoned; a tabs split is removed. Returns nil when
    /// `tabID` is not a live member.
    @discardableResult
    func separate(tabID: UUID) -> SidebarItem? {
        guard let tab = item(tabID), tab.kind == .site, let split = splitContainer(of: tabID) else { return nil }
        performBatch {
            let key = sortKey(
                for: .after(split.id),
                parentID: split.parentID,
                section: split.section,
                spaceID: split.spaceID,
                excluding: tabID
            )
            updateItem(tabID) {
                $0.spaceID = split.spaceID
                $0.section = split.section
                $0.parentID = split.parentID
                $0.sortKey = key
                $0.splitFraction = nil
            }
            clearSplitFractions(split.id)
            reconcileSplit(split.id)
        }
        return item(tabID)
    }

    /// Moves a member to `index` in the split's final order (0 = leftmost). Fractions stay on the member.
    func movePane(tabID: UUID, to index: Int) {
        guard let split = splitContainer(of: tabID) else { return }
        let members = splitMembers(of: split.id)
        guard let from = members.firstIndex(where: { $0.id == tabID }) else { return }
        let destination = min(max(index, 0), members.count - 1)
        guard destination != from else { return }
        let others = members.filter { $0.id != tabID }
        let insertion = min(destination, others.count)
        performBatch {
            let position = insertionPosition(at: insertion, in: others)
            let key = sortKey(
                for: position,
                parentID: split.id,
                section: split.section,
                spaceID: split.spaceID,
                excluding: tabID
            )
            updateItem(tabID) { $0.sortKey = key }
        }
    }

    /// Exchanges two panes by their indexes. Each member keeps its fraction.
    func swapPanes(splitID: UUID, _ first: Int, _ second: Int) {
        let members = splitMembers(of: splitID)
        guard members.indices.contains(first), members.indices.contains(second), first != second else { return }
        let left = members[first]
        let right = members[second]
        performBatch {
            let leftKey = left.sortKey
            let rightKey = right.sortKey
            updateItem(left.id) { $0.sortKey = rightKey }
            updateItem(right.id) { $0.sortKey = leftKey }
        }
    }

    /// Writes one share per current member, in pane order, normalized so the shares sum to 1.
    ///
    /// An empty array clears every share back to equal widths. Any other count, or a value that
    /// is not finite and greater than zero, leaves the split unchanged.
    func setFractions(splitID: UUID, _ fractions: [Double]) {
        let members = splitMembers(of: splitID)
        guard !members.isEmpty else { return }
        if fractions.isEmpty {
            guard members.contains(where: { $0.splitFraction != nil }) else { return }
            performBatch { clearSplitFractions(splitID) }
            return
        }
        guard fractions.count == members.count else { return }
        guard fractions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        let sum = fractions.reduce(0, +)
        guard sum > 0 else { return }
        let normalized = fractions.map { $0 / sum }
        performBatch {
            for (member, fraction) in zip(members, normalized) {
                updateItem(member.id) { $0.splitFraction = fraction }
            }
        }
    }

    /// Sets the split's axis. Horizontal is stored as `.horizontal` (nil still reads as horizontal).
    func setSplitAxis(splitID: UUID, _ axis: SidebarItem.SplitAxis) {
        guard item(splitID)?.isSplit == true else { return }
        updateItem(splitID) { $0.splitAxis = axis }
    }

    /// Drops a split that no longer has two live members.
    /// One member inherits the split's place. Zero members remove the empty split.
    func reconcileSplit(_ splitID: UUID) {
        guard let split = items[splitID], split.deletedAt == nil, split.kind == .split else { return }
        let members = splitMembers(of: splitID)
        switch members.count {
        case 0:
            removeSplitRecord(split)
        case 1:
            dissolve(split, keeping: members[0])
        default:
            break
        }
    }

    func clearSplitFractions(_ splitID: UUID) {
        for member in splitMembers(of: splitID) where member.splitFraction != nil {
            updateItem(member.id) { $0.splitFraction = nil }
        }
    }

    private func splitParent(for anchor: SidebarItem) -> UUID? {
        guard anchor.section == .pinned,
              let parentID = anchor.parentID,
              let parent = item(parentID),
              parent.isFolder,
              parent.spaceID == anchor.spaceID,
              parent.section == .pinned else { return nil }
        return parentID
    }

    private func insertionPosition(at index: Int, in members: [SidebarItem]) -> Position {
        if index <= 0 { return .start }
        if index >= members.count { return .end }
        return .before(members[index].id)
    }

    private func dissolve(_ split: SidebarItem, keeping member: SidebarItem) {
        updateItem(member.id) {
            $0.spaceID = split.spaceID
            $0.section = split.section
            $0.parentID = split.parentID
            $0.sortKey = split.sortKey
            $0.splitFraction = nil
        }
        removeSplitRecord(split)
    }

    private func removeSplitRecord(_ split: SidebarItem) {
        if split.isSynced {
            updateItem(split.id) { $0.deletedAt = .now }
        } else {
            items[split.id] = nil
            didChange([split.id])
        }
    }
}
