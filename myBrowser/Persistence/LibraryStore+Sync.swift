import Foundation

/// Values to write from a fetch or a conflict. Dates are the remote values; nothing here bumps `modifiedAt`.
nonisolated struct RemoteLibraryUpdate: Equatable, Sendable {
    var profiles: [Profile] = []
    var spaces: [Space] = []
    var items: [SidebarItem] = []
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
    func applyRemote(upserts: RemoteLibraryUpdate, deletions: Set<UUID>) {
        let savedChangeHandler = onChange
        onChange = nil
        defer { onChange = savedChangeHandler }

        var changed = false
        for profile in upserts.profiles {
            profiles[profile.id] = profile
            changed = true
        }
        for space in upserts.spaces {
            spaces[space.id] = space
            changed = true
        }
        for item in upserts.items where item.section != .tabs {
            items[item.id] = item
            changed = true
        }
        for id in deletions {
            if items[id]?.section == .tabs { continue }
            if profiles.removeValue(forKey: id) != nil { changed = true }
            if spaces.removeValue(forKey: id) != nil { changed = true }
            if items.removeValue(forKey: id) != nil { changed = true }
        }
        if changed { scheduleSave() }
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
        if !removed.isEmpty { scheduleSave() }
        return removed
    }
}
