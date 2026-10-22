import Foundation

/// Last-writer-wins for one record. Ties keep the server record so its change tag stays.
/// A tombstone and an edit with the same stamp keep the tombstone, so a delete is not resurrected.
nonisolated enum SyncConflict {
    struct Side: Equatable, Sendable {
        var modifiedAt: Date
        var deletedAt: Date?

        var isDeleted: Bool { deletedAt != nil }

        /// Later of `modifiedAt` and `deletedAt`. Deletes write both, but a tombstone must not hide behind an older edit stamp.
        var stamp: Date {
            if let deletedAt, deletedAt > modifiedAt { return deletedAt }
            return modifiedAt
        }
    }

    enum Winner: Equatable, Sendable {
        case local
        case server
    }

    /// What to do with a fetched or conflicting server record.
    enum Merge: Equatable, Sendable {
        case applyServer
        case uploadLocal
    }

    /// A save failed because the server record is gone (`unknownItem` / zone reset).
    enum MissingServer: Equatable, Sendable {
        /// Local edit is newer than the last server `modificationDate` we stored. Create the record again.
        case recreateLocal
        /// The server deletion stands. Remove the local copy.
        case dropLocal
        /// Local row is already a tombstone and the server no longer has the record.
        case deletionAlreadyDone
    }

    static func resolve(local: Side, server: Side) -> Winner {
        if local.stamp > server.stamp { return .local }
        if server.stamp > local.stamp { return .server }
        if local.isDeleted != server.isDeleted {
            return local.isDeleted ? .local : .server
        }
        return .server
    }

    static func merge(local: Side?, server: Side) -> Merge {
        guard let local else { return .applyServer }
        return resolve(local: local, server: server) == .server ? .applyServer : .uploadLocal
    }

    static func resolveMissingServerRecord(local: Side?, lastKnownServerModification: Date?) -> MissingServer {
        guard let local else { return .dropLocal }
        if local.isDeleted { return .deletionAlreadyDone }
        if let lastKnownServerModification, local.stamp > lastKnownServerModification {
            return .recreateLocal
        }
        return .dropLocal
    }
}
