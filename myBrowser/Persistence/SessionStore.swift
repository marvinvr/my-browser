import Foundation
import Observation

/// Local-only session state (never synced): selection, per-tab back/forward history, closed tabs, archive.
@Observable
final class SessionStore {
    nonisolated struct ClosedTab: Codable, Hashable, Sendable {
        var item: SidebarItem
        var interactionState: Data?
    }

    /// An unpinned tab closed by the archiver. The item id is the tab's id, so a reopen puts the same record back.
    nonisolated struct ArchivedTab: Codable, Hashable, Identifiable, Sendable {
        var item: SidebarItem
        var interactionState: Data?
        var archivedAt: Date
        /// When the tab was last selected before it was archived.
        var lastActiveAt: Date

        var id: UUID { item.id }
    }

    /// Recently closed tabs kept in memory and on disk. Oldest entries past this are dropped.
    static let closedTabLimit = 50

    var selectedSpaceID: UUID? { didSet { didChange() } }
    var selectedItemBySpace: [UUID: UUID] = [:] { didSet { didChange() } }
    /// `WKWebView.interactionState` per tab id.
    var interactionStates: [UUID: Data] = [:] { didSet { didChange() } }
    /// Focused pane of each split. Local only: the library records the panes, not which one is current.
    var focusedPaneBySplit: [UUID: UUID] = [:] { didSet { didChange() } }
    /// Most recent last.
    var closedTabs: [ClosedTab] = [] {
        didSet {
            if closedTabs.count > Self.closedTabLimit {
                closedTabs = Array(closedTabs.suffix(Self.closedTabLimit))
            }
            didChange()
        }
    }
    /// Last time each item was selected. Not stored on `SidebarItem`, so opening a pin does not rewrite a synced record.
    var lastActiveAt: [UUID: Date] = [:] { didSet { didChange() } }
    /// Most recent last. Entries older than `TabArchivePolicy.retention` are dropped on load and on each sweep.
    var archivedTabs: [ArchivedTab] = [] { didSet { didChange() } }
    var isSidebarVisible: Bool = true { didSet { didChange() } }

    /// `nil` = in-memory only (tests, previews). Never reads or writes disk.
    let directory: URL?

    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suppressSave = false

    private static let schemaVersion = 1
    private static let saveDelay: Duration = .milliseconds(500)

    init(directory: URL?) {
        self.directory = directory
        if directory != nil {
            load()
        }
    }

    /// Drops archived tabs past the retention window, and tabs whose space is gone when `spaceIsLive` is set.
    func pruneArchivedTabs(now: Date = .now, spaceIsLive: ((UUID) -> Bool)? = nil) {
        let kept = archivedTabs.filter { tab in
            if let spaceIsLive, !spaceIsLive(tab.item.spaceID) { return false }
            return !TabArchivePolicy.isExpired(archivedAt: tab.archivedAt, now: now)
        }
        guard kept.count != archivedTabs.count else { return }
        archivedTabs = kept
    }

    /// Drops interaction states for tabs that are no longer open.
    func prune(keeping ids: Set<UUID>) {
        let pruned = interactionStates.filter { ids.contains($0.key) }
        guard pruned.count != interactionStates.count else { return }
        interactionStates = pruned
    }

    /// Writes pending changes immediately. No-op when clean, or when `directory` is nil.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        writeIfDirty()
    }

    private func didChange() {
        guard !suppressSave else { return }
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
        let snapshot: SessionSnapshot
        do {
            guard let loaded = try JSONFileStorage.read(SessionSnapshot.self, from: url) else { return }
            guard loaded.schemaVersion == Self.schemaVersion else {
                JSONFileStorage.quarantine(url)
                return
            }
            snapshot = loaded
        } catch {
            return
        }

        let overflowed = snapshot.closedTabs.count > Self.closedTabLimit
        let freshArchive = snapshot.archivedTabs.filter {
            !TabArchivePolicy.isExpired(archivedAt: $0.archivedAt, now: .now)
        }
        let prunedArchive = freshArchive.count != snapshot.archivedTabs.count
        suppressSave = true
        selectedSpaceID = snapshot.selectedSpaceID
        selectedItemBySpace = snapshot.selectedItemBySpace
        interactionStates = snapshot.interactionStates
        focusedPaneBySplit = snapshot.focusedPaneBySplit
        isSidebarVisible = snapshot.isSidebarVisible
        lastActiveAt = snapshot.lastActiveAt
        archivedTabs = freshArchive
        closedTabs = Array(snapshot.closedTabs.suffix(Self.closedTabLimit))
        suppressSave = false
        if overflowed || prunedArchive {
            scheduleSave()
        }
    }

    private func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            schemaVersion: Self.schemaVersion,
            selectedSpaceID: selectedSpaceID,
            selectedItemBySpace: selectedItemBySpace,
            interactionStates: interactionStates,
            closedTabs: closedTabs,
            isSidebarVisible: isSidebarVisible,
            focusedPaneBySplit: focusedPaneBySplit,
            lastActiveAt: lastActiveAt,
            archivedTabs: archivedTabs
        )
    }

    private func fileURL(in directory: URL) -> URL {
        directory.appending(path: "session.json", directoryHint: .notDirectory)
    }
}

nonisolated private struct SessionSnapshot: Codable, Sendable {
    var schemaVersion: Int
    var selectedSpaceID: UUID?
    var selectedItemBySpace: [UUID: UUID]
    var interactionStates: [UUID: Data]
    var closedTabs: [SessionStore.ClosedTab]
    var isSidebarVisible: Bool
    /// Missing in session files written before split view.
    var focusedPaneBySplit: [UUID: UUID]
    var lastActiveAt: [UUID: Date]
    var archivedTabs: [SessionStore.ArchivedTab]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedSpaceID
        case selectedItemBySpace
        case interactionStates
        case closedTabs
        case isSidebarVisible
        case focusedPaneBySplit
        case lastActiveAt
        case archivedTabs
    }

    init(
        schemaVersion: Int,
        selectedSpaceID: UUID?,
        selectedItemBySpace: [UUID: UUID],
        interactionStates: [UUID: Data],
        closedTabs: [SessionStore.ClosedTab],
        isSidebarVisible: Bool,
        focusedPaneBySplit: [UUID: UUID],
        lastActiveAt: [UUID: Date],
        archivedTabs: [SessionStore.ArchivedTab]
    ) {
        self.schemaVersion = schemaVersion
        self.selectedSpaceID = selectedSpaceID
        self.selectedItemBySpace = selectedItemBySpace
        self.interactionStates = interactionStates
        self.closedTabs = closedTabs
        self.isSidebarVisible = isSidebarVisible
        self.focusedPaneBySplit = focusedPaneBySplit
        self.lastActiveAt = lastActiveAt
        self.archivedTabs = archivedTabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        selectedSpaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedSpaceID)
        selectedItemBySpace = try container.decodeIfPresent([UUID: UUID].self, forKey: .selectedItemBySpace) ?? [:]
        interactionStates = try container.decodeIfPresent([UUID: Data].self, forKey: .interactionStates) ?? [:]
        closedTabs = try container.decodeIfPresent([SessionStore.ClosedTab].self, forKey: .closedTabs) ?? []
        isSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true
        // Older session files predate split focus and the archive. Missing keys stay empty.
        focusedPaneBySplit = try container.decodeIfPresent([UUID: UUID].self, forKey: .focusedPaneBySplit) ?? [:]
        lastActiveAt = try container.decodeIfPresent([UUID: Date].self, forKey: .lastActiveAt) ?? [:]
        archivedTabs = try container.decodeIfPresent([SessionStore.ArchivedTab].self, forKey: .archivedTabs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(selectedSpaceID, forKey: .selectedSpaceID)
        try container.encode(selectedItemBySpace, forKey: .selectedItemBySpace)
        try container.encode(interactionStates, forKey: .interactionStates)
        try container.encode(closedTabs, forKey: .closedTabs)
        try container.encode(isSidebarVisible, forKey: .isSidebarVisible)
        try container.encode(focusedPaneBySplit, forKey: .focusedPaneBySplit)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encode(archivedTabs, forKey: .archivedTabs)
    }
}
