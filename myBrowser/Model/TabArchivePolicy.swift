import Foundation

/// One sidebar item as the archiver sees it. The clock and the flags are passed in so tests do not need WebKit.
nonisolated struct TabArchiveCandidate: Equatable, Sendable {
    var id: UUID
    var section: SidebarItem.Section
    var kind: SidebarItem.Kind
    var lastActiveAt: Date?
    var isSelected: Bool
    var isPlayingMedia: Bool
    var isPictureInPicture: Bool
    var hasActiveDownload: Bool
}

/// Which unpinned tabs to close, and which archived entries have expired.
/// Idle time has to be longer than the interval: equal to the interval stays open.
nonisolated enum TabArchivePolicy {
    /// Sweep cadence. Launch and app activation also sweep.
    static let checkInterval: Duration = .seconds(180)

    /// Archived tabs older than this are dropped. About 30 days.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Ids to archive, oldest activity first so the most recently used is last on the reopen stack.
    static func idsToArchive(_ candidates: [TabArchiveCandidate], interval: TimeInterval?, now: Date) -> [UUID] {
        guard let interval else { return [] }
        return candidates
            .filter { candidate in
                guard candidate.section == .tabs, candidate.kind == .site else { return false }
                guard !candidate.isSelected else { return false }
                guard !candidate.isPlayingMedia, !candidate.isPictureInPicture, !candidate.hasActiveDownload else { return false }
                guard let lastActiveAt = candidate.lastActiveAt else { return false }
                return now.timeIntervalSince(lastActiveAt) > interval
            }
            .sorted { lhs, rhs in
                let left = lhs.lastActiveAt ?? .distantPast
                let right = rhs.lastActiveAt ?? .distantPast
                if left != right { return left < right }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map(\.id)
    }

    static func isExpired(archivedAt: Date, now: Date, retention: TimeInterval = retention) -> Bool {
        now.timeIntervalSince(archivedAt) > retention
    }
}
