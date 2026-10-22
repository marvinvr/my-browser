import Foundation
import Observation

/// Local-only session state (never synced): selection, per-tab back/forward history, closed tabs.
@Observable
final class SessionStore {
    nonisolated struct ClosedTab: Codable, Hashable, Sendable {
        var item: SidebarItem
        var interactionState: Data?
    }

    /// Recently closed tabs kept in memory and on disk. Oldest entries past this are dropped.
    static let closedTabLimit = 50

    var selectedSpaceID: UUID? { didSet { didChange() } }
    var selectedItemBySpace: [UUID: UUID] = [:] { didSet { didChange() } }
    /// `WKWebView.interactionState` per tab id.
    var interactionStates: [UUID: Data] = [:] { didSet { didChange() } }
    /// Most recent last.
    var closedTabs: [ClosedTab] = [] {
        didSet {
            if closedTabs.count > Self.closedTabLimit {
                closedTabs = Array(closedTabs.suffix(Self.closedTabLimit))
            }
            didChange()
        }
    }
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
        suppressSave = true
        selectedSpaceID = snapshot.selectedSpaceID
        selectedItemBySpace = snapshot.selectedItemBySpace
        interactionStates = snapshot.interactionStates
        isSidebarVisible = snapshot.isSidebarVisible
        closedTabs = Array(snapshot.closedTabs.suffix(Self.closedTabLimit))
        suppressSave = false
        if overflowed {
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
            isSidebarVisible: isSidebarVisible
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
}
