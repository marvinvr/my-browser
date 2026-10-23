import Foundation

/// Values to write from a fetch or a conflict. Dates are the remote values; nothing here bumps `modifiedAt`.
nonisolated struct RemoteLibraryUpdate: Equatable, Sendable {
    var profiles: [Profile] = []
    var spaces: [Space] = []
    var items: [SidebarItem] = []
}

/// What to do with the launch placeholder around the first fetch.
enum PlaceholderSync {
    enum Decision: Equatable {
        case upload(Set<UUID>)
        case drop(Set<UUID>)
    }

    /// After the first fetch. Other live spaces mean iCloud already has a library:
    /// drop the placeholder instead of uploading it. No other space means upload it.
    static func afterFetch(placeholderIDs: Set<UUID>, liveSpaceIDs: Set<UUID>) -> Decision {
        let others = liveSpaceIDs.subtracting(placeholderIDs)
        if others.isEmpty { return .upload(placeholderIDs) }
        return .drop(placeholderIDs)
    }
}

/// Footer after a fetch or a send finishes.
enum SyncActivityStatus {
    /// A failed save stays paused. Pending zone changes stay on syncing.
    static func text(paused: Bool, hasPendingChanges: Bool) -> String {
        if paused { return SyncController.pausedStatus }
        if hasPendingChanges { return SyncController.syncingStatus }
        return SyncController.idleStatus
    }
}

/// One unsent library change. `.tabs` rows are never included.
nonisolated enum PendingSyncChange: Equatable, Sendable {
    case save(UUID)
    case delete(UUID)

    var id: UUID {
        switch self {
        case .save(let id), .delete(let id): id
        }
    }
}

extension LibraryStore {
    /// Writes a remote batch without echoing it through `onChange`.
    /// `onChange` is cleared for the call (`applyingRemote`) so the sync engine does not upload the same rows back.
    /// Deletions run after upserts. A `.tabs` row is left untouched.
    /// An invalid `sortKey` is replaced with a key after the last valid sibling.
    ///
    /// A split that already existed reconciles when one of its members is deleted or tombstoned.
    /// A container that arrives in this batch with only some of its members is not dissolved.
    func applyRemote(upserts: RemoteLibraryUpdate, deletions: Set<UUID>) {
        let existingLiveSplits = Set(items.values.compactMap { item -> UUID? in
            guard item.kind == .split, item.deletedAt == nil else { return nil }
            return item.id
        })
        var splitsLosingAMember: Set<UUID> = []
        func noteMemberLoss(_ item: SidebarItem?) {
            guard let item, item.kind == .site, let parentID = item.parentID else { return }
            splitsLosingAMember.insert(parentID)
        }
        for id in deletions {
            noteMemberLoss(items[id])
        }
        for item in upserts.items where item.section != .tabs && item.deletedAt != nil {
            noteMemberLoss(item)
            noteMemberLoss(items[item.id])
        }

        let savedChangeHandler = onChange
        onChange = nil

        var changed = false
        for profile in upserts.profiles {
            profiles[profile.id] = profile
            changed = true
        }
        for var space in upserts.spaces {
            if !SortKey.isValid(space.sortKey) {
                space.sortKey = sortKeyAfterLastSpace(excluding: space.id)
            }
            spaces[space.id] = space
            changed = true
        }
        for var item in upserts.items where item.section != .tabs {
            if !SortKey.isValid(item.sortKey) {
                item.sortKey = sortKeyAfterLastSibling(of: item)
            }
            items[item.id] = item
            changed = true
        }
        for id in deletions {
            if items[id]?.section == .tabs { continue }
            if profiles.removeValue(forKey: id) != nil { changed = true }
            if spaces.removeValue(forKey: id) != nil { changed = true }
            if items.removeValue(forKey: id) != nil { changed = true }
        }
        onChange = savedChangeHandler
        if changed {
            refreshSiblingLists()
            scheduleSave()
            onRemoteApplied?()
        }
        for splitID in splitsLosingAMember where existingLiveSplits.contains(splitID) {
            reconcileSplit(splitID)
        }
    }

    /// Saves and deletes to enqueue for `ids`. Unknown ids and `.tabs` rows are skipped
    /// (a hard-deleted tab must not become a CloudKit delete).
    func pendingChanges(for ids: Set<UUID>) -> [PendingSyncChange] {
        ids.compactMap { id in
            if let profile = profiles[id] {
                return profile.deletedAt == nil ? .save(id) : .delete(id)
            }
            if let space = spaces[id] {
                return space.deletedAt == nil ? .save(id) : .delete(id)
            }
            if let item = items[id], item.isSynced {
                return item.deletedAt == nil ? .save(id) : .delete(id)
            }
            return nil
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func syncSide(for id: UUID) -> SyncConflict.Side? {
        if let profile = profiles[id] {
            return SyncConflict.Side(modifiedAt: profile.modifiedAt, deletedAt: profile.deletedAt)
        }
        if let space = spaces[id] {
            return SyncConflict.Side(modifiedAt: space.modifiedAt, deletedAt: space.deletedAt)
        }
        if let item = items[id], item.isSynced {
            return SyncConflict.Side(modifiedAt: item.modifiedAt, deletedAt: item.deletedAt)
        }
        return nil
    }

    /// Drops tombstones whose deletion has been sent and whose `deletedAt` is older than `cutoff`.
    /// Does not call `onChange`. Returns the ids removed.
    @discardableResult
    func purgeAcknowledgedTombstones(
        sent: Set<UUID>,
        olderThan cutoff: Date = .now.addingTimeInterval(-30 * 24 * 60 * 60)
    ) -> Set<UUID> {
        guard !sent.isEmpty else { return [] }
        let savedChangeHandler = onChange
        onChange = nil
        defer { onChange = savedChangeHandler }

        var removed: Set<UUID> = []
        for id in sent {
            if let profile = profiles[id], let deletedAt = profile.deletedAt, deletedAt < cutoff {
                profiles[id] = nil
                removed.insert(id)
            }
            if let space = spaces[id], let deletedAt = space.deletedAt, deletedAt < cutoff {
                spaces[id] = nil
                removed.insert(id)
            }
            if let item = items[id], item.isSynced, let deletedAt = item.deletedAt, deletedAt < cutoff {
                items[id] = nil
                removed.insert(id)
            }
        }
        if !removed.isEmpty {
            refreshSiblingLists()
            scheduleSave()
        }
        return removed
    }

    /// The launch placeholder, when it is the entire synced library: one untouched Personal space
    /// (`person.fill`, blue, no emoji) and its profile, with no synced items and no tombstones.
    /// Local tabs do not count. A rename, a pin, or a second space is not a placeholder.
    var untouchedPlaceholderIDs: Set<UUID> {
        let liveSpaces = spaces.values.filter { $0.deletedAt == nil }
        let liveProfiles = profiles.values.filter { $0.deletedAt == nil }
        let syncedLiveItems = items.values.contains { $0.deletedAt == nil && $0.isSynced }
        let tombstones = spaces.values.contains { $0.deletedAt != nil }
            || profiles.values.contains { $0.deletedAt != nil }
            || items.values.contains { $0.deletedAt != nil && $0.isSynced }
        guard !tombstones, !syncedLiveItems,
              liveSpaces.count == 1, liveProfiles.count == 1,
              let space = liveSpaces.first, let profile = liveProfiles.first,
              space.profileID == profile.id,
              Self.isUntouchedPlaceholder(space, profile: profile) else { return [] }
        return [space.id, profile.id]
    }

    /// True when `ids` is still the untouched placeholder, even if a fetch has added other spaces.
    func placeholderStillUntouched(_ ids: Set<UUID>) -> Bool {
        let liveSpaces = ids.compactMap { spaces[$0] }.filter { $0.deletedAt == nil }
        let liveProfiles = ids.compactMap { profiles[$0] }.filter { $0.deletedAt == nil }
        guard liveSpaces.count == 1, liveProfiles.count == 1,
              let space = liveSpaces.first, let profile = liveProfiles.first,
              Self.isUntouchedPlaceholder(space, profile: profile) else { return false }
        // A pin or a tombstone in this space means the user edited it during the fetch.
        return !items.values.contains { $0.isSynced && $0.spaceID == space.id }
    }

    /// Removes that placeholder, its profile, and its local tabs. Does not call `onChange`,
    /// so a row that was never uploaded is not deleted in CloudKit. No-op if `ids` was edited.
    @discardableResult
    func discardPlaceholder(_ ids: Set<UUID>) -> Set<UUID> {
        guard placeholderStillUntouched(ids) else { return [] }
        let savedChangeHandler = onChange
        onChange = nil
        let spaceIDs = Set(ids.filter { spaces[$0] != nil })
        let owned = items.compactMap { itemID, item in spaceIDs.contains(item.spaceID) ? itemID : nil }
        for itemID in owned {
            items[itemID] = nil
        }
        for id in ids {
            profiles[id] = nil
            spaces[id] = nil
        }
        onChange = savedChangeHandler
        refreshSiblingLists()
        scheduleSave()
        onRemoteApplied?()
        return ids
    }

    static func isUntouchedPlaceholder(_ space: Space, profile: Profile) -> Bool {
        space.deletedAt == nil && profile.deletedAt == nil
            && space.profileID == profile.id
            && space.name == "Personal" && profile.name == "Personal"
            && space.symbol == "person.fill" && space.emoji == nil
            && space.color == .blue
    }

    /// A valid key after the last live space, ignoring `excluding` and any key `SortKey` would reject.
    private func sortKeyAfterLastSpace(excluding: UUID) -> String {
        let last = spaces.values
            .filter { $0.id != excluding && $0.deletedAt == nil && SortKey.isValid($0.sortKey) }
            .max { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
        return SortKey.between(last?.sortKey, nil)
    }

    /// A valid key after the last live sibling of `item` (same space, section, and parent).
    private func sortKeyAfterLastSibling(of item: SidebarItem) -> String {
        let last = storedChildren(of: item.parentID, section: item.section, in: item.spaceID)
            .last { $0.id != item.id && SortKey.isValid($0.sortKey) }
        return SortKey.between(last?.sortKey, nil)
    }
}
