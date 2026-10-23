import Foundation

/// One pane of `DisplayedContent`, left to right (or top to bottom).
struct DisplayedPane: Identifiable {
    var id: UUID
    /// Share of the content area. Nil means this pane matches its siblings.
    var fraction: Double?
    var tab: BrowserTab
}

/// What the content area shows for a sidebar selection.
///
/// A site is one pane. A split, and any of its members, is the split's panes in order.
/// `fraction` nil on every pane means equal sizes. `BrowserModel.displayedContent(for:)`
/// creates unloaded `BrowserTab`s for panes that don't have one yet. It does not load
/// web views; `select` / `focusPane` do that.
struct DisplayedContent {
    /// The sidebar row: a site id, or the split id when `isSplit` is true.
    var itemID: UUID
    var isSplit: Bool
    var axis: SidebarItem.SplitAxis
    var panes: [DisplayedPane]
    /// The pane the toolbar, URL, and back/forward act on.
    var focusedID: UUID
}

extension BrowserModel {
    /// Content for the current selection. Nil when nothing selectable is selected.
    var displayedContent: DisplayedContent? { displayedContent(for: nil) }

    /// Content for `itemID`, or the current selection when `itemID` is nil.
    ///
    /// A member id resolves to its split, focused on that member. The returned tabs exist
    /// in `tabs` but their web views load only when the split is shown (`select`) or a pane
    /// is focused. The first selection of a split loads every pane. A later focus change
    /// loads the focused pane only, so a closed pinned pane stays unloaded until then.
    /// Selecting the split again after leaving it loads any pane that is not already loaded.
    func displayedContent(for itemID: UUID?) -> DisplayedContent? {
        let id = itemID ?? selectedItemID
        guard let id, let item = library.item(id) else { return nil }
        if let split = splitItem(containing: item) {
            let members = library.splitMembers(of: split.id)
            guard members.count >= SidebarItem.minimumSplitMembers else { return nil }
            let fractions = SidebarItem.displayFractions(for: members)
            let panes = zip(members, fractions).map { member, fraction in
                DisplayedPane(id: member.id, fraction: fraction, tab: ensureTab(for: member))
            }
            let focus = item.kind == .site && members.contains(where: { $0.id == id })
                ? id
                : (resolvedFocus(in: split.id) ?? members[0].id)
            return DisplayedContent(
                itemID: split.id,
                isSplit: true,
                axis: split.resolvedSplitAxis,
                panes: panes,
                focusedID: focus
            )
        }
        guard item.kind == .site else { return nil }
        let tab = ensureTab(for: item)
        return DisplayedContent(
            itemID: id,
            isSplit: false,
            axis: .horizontal,
            panes: [DisplayedPane(id: id, fraction: nil, tab: tab)],
            focusedID: id
        )
    }

    /// Groups 2...4 sites into one split at the first site's place and selects it.
    ///
    /// Focus is the site that was current when it is one of the members, otherwise the first pane.
    /// Returns nil when `LibraryStore.createSplit` rejects the ids. See that method for the rules.
    @discardableResult
    func createSplit(tabIDs: [UUID], axis: SidebarItem.SplitAxis = .horizontal) -> SidebarItem? {
        let previous = selectedItemID
        let previousFocus = previous.flatMap { library.item($0)?.isSplit == true ? resolvedFocus(in: $0) : $0 }
        let storedAxis: SidebarItem.SplitAxis? = axis == .horizontal ? nil : axis
        guard let split = library.createSplit(tabIDs: tabIDs, axis: storedAxis) else { return nil }
        let members = library.splitMembers(of: split.id)
        let focus = members.first { $0.id == previousFocus }?.id ?? members.first?.id
        if let focus {
            session.focusedPaneBySplit[split.id] = focus
        }
        select(split.id)
        return library.item(split.id)
    }

    /// Adds a site to a split at `index` (0 = leftmost) and returns the moved site.
    ///
    /// When `tabID` was the selected site, the split becomes selected and that pane is focused.
    /// Adding a pane while the split is already selected loads the new pane.
    /// Returns nil when the store rejects the add (full split, other space, not a site).
    @discardableResult
    func addToSplit(tabID: UUID, splitID: UUID, at index: Int) -> SidebarItem? {
        let wasSelected = selectedItemID == tabID
        guard library.addToSplit(tabID: tabID, splitID: splitID, at: index) != nil else { return nil }
        if wasSelected {
            session.focusedPaneBySplit[splitID] = tabID
            select(splitID)
        } else if selectedItemID == splitID, let item = library.item(tabID) {
            let tab = ensureTab(for: item)
            let created = !tab.isLoaded
            tab.loadIfNeeded(using: profiles)
            if created { extensions?.tabOpened(tab) }
        }
        return library.item(tabID)
    }

    /// Pulls a member out and places it immediately after the split.
    ///
    /// The split dissolves when one member would remain; that member takes the split's place.
    /// When the removed pane was focused, it becomes the selection. Otherwise a dissolved
    /// split leaves the surviving member selected if the split was selected.
    @discardableResult
    func separate(tabID: UUID) -> SidebarItem? {
        guard let split = library.splitContainer(of: tabID) else { return nil }
        let wasFocused = resolvedFocus(in: split.id) == tabID
        let splitSelected = session.selectedItemBySpace[split.spaceID] == split.id
        let previous = library.splitMembers(of: split.id).map(\.id)
        guard library.separate(tabID: tabID) != nil else { return nil }
        repairSplit(
            splitID: split.id,
            detachedID: tabID,
            previousMemberIDs: previous,
            selectDetached: splitSelected && wasFocused
        )
        return library.item(tabID)
    }

    /// Same as `separate(tabID:)`.
    @discardableResult
    func removeFromSplit(tabID: UUID) -> SidebarItem? {
        separate(tabID: tabID)
    }

    /// Moves a pane to `index` in the split's final order (0 = leftmost). The focused pane stays focused.
    func movePane(tabID: UUID, to index: Int) {
        library.movePane(tabID: tabID, to: index)
    }

    /// Exchanges the panes at two indexes. Fractions stay with the sites, so a wide pane stays wide.
    func swapPanes(splitID: UUID, _ first: Int, _ second: Int) {
        library.swapPanes(splitID: splitID, first, second)
    }

    /// One positive share per pane, in order. Values are scaled to sum to 1.
    /// Pass `[]` to return to equal widths. Invalid input is ignored.
    func setFractions(splitID: UUID, _ fractions: [Double]) {
        library.setFractions(splitID: splitID, fractions)
    }

    /// Horizontal is side by side. Vertical stacks the panes.
    func setSplitAxis(splitID: UUID, _ axis: SidebarItem.SplitAxis) {
        library.setSplitAxis(splitID: splitID, axis)
    }

    /// Selects the member's split and makes this pane the one the toolbar drives.
    /// No-op when `tabID` is not inside a split.
    func focusPane(tabID: UUID) {
        guard library.splitContainer(of: tabID) != nil else { return }
        select(tabID)
    }

    /// The selection can become a split, or a selected split still has room for a pane.
    var canOpenInSplitView: Bool {
        guard let id = selectedItemID, let item = library.item(id) else { return false }
        if item.isSplit {
            return library.splitMembers(of: id).count < SidebarItem.maximumSplitMembers
        }
        return canStartSplit(from: id)
    }

    /// The selection is a split with at least two panes.
    var canSeparatePane: Bool {
        guard let id = selectedItemID, library.item(id)?.isSplit == true else { return false }
        return library.splitMembers(of: id).count >= SidebarItem.minimumSplitMembers
    }

    /// The selection is a split of exactly two panes.
    var canSwapPanes: Bool {
        guard let id = selectedItemID else { return false }
        return library.splitMembers(of: id).count == 2
    }

    /// A loose pinned or tabs site. Favorites and panes that are already in a split cannot start another.
    func canStartSplit(from itemID: UUID) -> Bool {
        guard let item = library.item(itemID), item.kind == .site else { return false }
        guard item.section == .pinned || item.section == .tabs else { return false }
        return library.splitContainer(of: itemID) == nil
    }

    /// The selected site, when it can share a new split with `itemID`.
    func selectedSplitPartner(for itemID: UUID) -> SidebarItem? {
        guard canStartSplit(from: itemID), let item = library.item(itemID) else { return nil }
        guard let selected = selectedItemID, selected != itemID, let partner = library.item(selected) else { return nil }
        guard canStartSplit(from: partner.id), partner.spaceID == item.spaceID else { return nil }
        return partner
    }

    /// The selected split, when `itemID` can be added and the split has fewer than four panes.
    func selectedSplitToJoin(for itemID: UUID) -> SidebarItem? {
        guard canStartSplit(from: itemID), let item = library.item(itemID) else { return nil }
        guard let selected = selectedItemID, let split = library.item(selected), split.isSplit else { return nil }
        guard split.spaceID == item.spaceID else { return nil }
        guard library.splitMembers(of: split.id).count < SidebarItem.maximumSplitMembers else { return nil }
        return split
    }

    /// Other root tabs in the same space, in sidebar order. The selected partner is left out.
    func recentSplitPartners(for itemID: UUID, limit: Int = 8) -> [SidebarItem] {
        guard canStartSplit(from: itemID), let item = library.item(itemID), limit > 0 else { return [] }
        let partnerID = selectedSplitPartner(for: itemID)?.id
        return library.children(of: nil, section: .tabs, in: item.spaceID).filter { candidate in
            candidate.kind == .site
                && candidate.id != itemID
                && candidate.id != partnerID
                && library.splitContainer(of: candidate.id) == nil
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Groups the selected site with a new empty tab, or adds one to the selected split.
    ///
    /// The new pane is focused and the command bar opens on it. Returns false when the
    /// selection cannot grow a split (a favorite, a folder, or a split that already has four panes).
    @discardableResult
    func openInSplitView() -> Bool {
        guard let id = selectedItemID else { return false }
        return openInSplitView(anchoredOn: id)
    }

    /// Same as `openInSplitView()`, using `itemID` as the anchor instead of the selection.
    @discardableResult
    func openInSplitView(anchoredOn itemID: UUID) -> Bool {
        guard let item = library.item(itemID) else { return false }
        if item.isSplit {
            return addBlankPane(to: item.id)
        }
        if item.kind == .site, let split = library.splitContainer(of: itemID) {
            return addBlankPane(to: split.id)
        }
        guard canStartSplit(from: itemID) else { return false }
        guard let blank = makeBlankTab(in: item.spaceID) else { return false }
        guard createSplit(tabIDs: [item.id, blank.id]) != nil else {
            library.deleteItem(blank.id)
            return false
        }
        focusPane(tabID: blank.id)
        presentCommandBar(.editCurrent)
        return true
    }

    /// Pulls the focused pane out of the selected split.
    func separateFocusedPane() {
        guard let id = selectedItemID, library.item(id)?.isSplit == true, let focus = resolvedFocus(in: id) else { return }
        separate(tabID: focus)
    }

    /// Releases every pane. The first pane keeps the split's place; the others follow it in order.
    func separateAllPanes(of splitID: UUID? = nil) {
        let id = splitID ?? selectedItemID
        guard let id, library.item(id)?.isSplit == true else { return }
        let members = library.splitMembers(of: id)
        for member in members.dropFirst().reversed() {
            separate(tabID: member.id)
        }
    }

    /// Exchanges the two panes of the selected split. No-op unless there are exactly two.
    func swapFocusedPanes() {
        guard let id = selectedItemID, library.splitMembers(of: id).count == 2 else { return }
        swapPanes(splitID: id, 0, 1)
    }

    /// Moves focus to the next pane, wrapping. `offset` -1 goes to the previous pane.
    func focusAdjacentPane(offset: Int) {
        guard offset != 0, let id = selectedItemID, library.item(id)?.isSplit == true else { return }
        let members = library.splitMembers(of: id)
        guard members.count > 1, let focus = resolvedFocus(in: id),
              let index = members.firstIndex(where: { $0.id == focus }) else { return }
        let count = members.count
        let next = (index + ((offset % count) + count) % count) % count
        guard next != index else { return }
        focusPane(tabID: members[next].id)
    }

    private func addBlankPane(to splitID: UUID) -> Bool {
        guard let split = library.item(splitID), split.isSplit else { return false }
        let members = library.splitMembers(of: splitID)
        guard members.count < SidebarItem.maximumSplitMembers else { return false }
        guard let blank = makeBlankTab(in: split.spaceID) else { return false }
        guard addToSplit(tabID: blank.id, splitID: splitID, at: members.count) != nil else {
            library.deleteItem(blank.id)
            return false
        }
        focusPane(tabID: blank.id)
        presentCommandBar(.editCurrent)
        return true
    }

    private func makeBlankTab(in spaceID: UUID) -> SidebarItem? {
        guard library.space(spaceID) != nil else { return nil }
        return library.addItem(
            spaceID: spaceID,
            section: .tabs,
            kind: .site,
            title: "New Tab",
            url: nil,
            at: .start
        )
    }

    /// Pane id to highlight when `itemID` is the selection. Members and ordinary sites return themselves.
    func navigableAnchor(for itemID: UUID?) -> UUID? {
        guard let itemID, let item = library.item(itemID) else { return itemID }
        if item.isSplit {
            return resolvedFocus(in: itemID) ?? library.splitMembers(of: itemID).first?.id
        }
        return itemID
    }

    /// Stored focus when that site is still a member; otherwise the first pane.
    func resolvedFocus(in splitID: UUID) -> UUID? {
        let members = library.splitMembers(of: splitID)
        guard !members.isEmpty else { return nil }
        if let stored = session.focusedPaneBySplit[splitID], members.contains(where: { $0.id == stored }) {
            return stored
        }
        return members[0].id
    }

    /// Fixes selection and focus after `detachedID` leaves `splitID`.
    func repairSplit(
        splitID: UUID,
        detachedID: UUID,
        previousMemberIDs: [UUID],
        selectDetached: Bool
    ) {
        let spaces = session.selectedItemBySpace.filter { $0.value == splitID }.map(\.key)
        let live = library.item(splitID)?.isSplit == true
        if live {
            let members = library.splitMembers(of: splitID)
            let stored = session.focusedPaneBySplit[splitID]
            if stored == nil || stored == detachedID || !members.contains(where: { $0.id == stored }) {
                session.focusedPaneBySplit[splitID] = members.first?.id
            }
            if selectDetached, library.item(detachedID) != nil {
                select(detachedID)
            } else if spaces.contains(selectedSpaceID) {
                select(splitID)
            }
            return
        }
        session.focusedPaneBySplit[splitID] = nil
        let survivor = previousMemberIDs.first { $0 != detachedID && library.item($0) != nil }
        let replacement = selectDetached && library.item(detachedID) != nil ? detachedID : survivor
        for space in spaces {
            adoptSelection(replacement, in: space)
        }
    }

    private func splitItem(containing item: SidebarItem) -> SidebarItem? {
        if item.isSplit { return item }
        return library.splitContainer(of: item.id)
    }

    private func adoptSelection(_ id: UUID?, in spaceID: UUID) {
        if spaceID == selectedSpaceID {
            if let id {
                select(id)
            } else {
                session.selectedItemBySpace[spaceID] = nil
                refreshNavigationState()
            }
        } else {
            session.selectedItemBySpace[spaceID] = id
        }
    }
}
