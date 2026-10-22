import CloudKit
import Foundation

/// `sync-state.json`: CKSyncEngine state serialization, per-record system fields, and deletions the server has accepted.
final class SyncState {
    static let fileName = "sync-state.json"
    private static let schemaVersion = 1

    let directory: URL?
    private(set) var engineState: Data?
    private(set) var systemFields: [String: Data] = [:]
    private(set) var acknowledgedDeletions: Set<UUID> = []
    private(set) var awaitingAccountChoice = false

    private var writeDepth = 0

    init(directory: URL?) {
        self.directory = directory
        load()
    }

    func serialization() -> CKSyncEngine.State.Serialization? {
        guard let engineState else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: engineState)
    }

    func setSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        engineState = data
        touch()
    }

    func setEngineState(_ data: Data?) {
        engineState = data
        touch()
    }

    func systemFields(for id: UUID) -> Data? {
        systemFields[id.uuidString]
    }

    func setSystemFields(_ data: Data, for id: UUID) {
        systemFields[id.uuidString] = data
        touch()
    }

    func removeSystemFields(for id: UUID) {
        guard systemFields.removeValue(forKey: id.uuidString) != nil else { return }
        touch()
    }

    func clearSystemFields() {
        guard !systemFields.isEmpty else { return }
        systemFields = [:]
        touch()
    }

    func markDeletionSent(_ ids: some Sequence<UUID>) {
        let before = acknowledgedDeletions.count
        acknowledgedDeletions.formUnion(ids)
        guard acknowledgedDeletions.count != before else { return }
        touch()
    }

    func removeAcknowledgedDeletions(_ ids: Set<UUID>) {
        let before = acknowledgedDeletions.count
        acknowledgedDeletions.subtract(ids)
        guard acknowledgedDeletions.count != before else { return }
        touch()
    }

    func setAwaitingAccountChoice(_ awaiting: Bool) {
        guard awaitingAccountChoice != awaiting else { return }
        awaitingAccountChoice = awaiting
        touch()
    }

    /// Drops engine metadata. Library records are left alone.
    func reset(awaitingAccountChoice: Bool = false) {
        engineState = nil
        systemFields = [:]
        acknowledgedDeletions = []
        self.awaitingAccountChoice = awaitingAccountChoice
        touch()
    }

    /// Coalesces the writes from one sync event into a single file replace.
    func performBatch(_ body: () -> Void) {
        writeDepth += 1
        defer {
            writeDepth -= 1
            if writeDepth == 0 { write() }
        }
        body()
    }

    private func touch() {
        if writeDepth == 0 { write() }
    }

    private func fileURL(in directory: URL) -> URL {
        directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    private func load() {
        guard let directory else { return }
        let url = fileURL(in: directory)
        guard let snapshot = try? JSONFileStorage.read(Snapshot.self, from: url) else { return }
        guard snapshot.schemaVersion == Self.schemaVersion else {
            JSONFileStorage.quarantine(url)
            return
        }
        engineState = snapshot.engineState
        systemFields = snapshot.systemFields
        acknowledgedDeletions = Set(snapshot.acknowledgedDeletions.compactMap(UUID.init(uuidString:)))
        awaitingAccountChoice = snapshot.awaitingAccountChoice
    }

    private func write() {
        guard let directory else { return }
        let snapshot = Snapshot(
            schemaVersion: Self.schemaVersion,
            engineState: engineState,
            systemFields: systemFields,
            acknowledgedDeletions: acknowledgedDeletions.map(\.uuidString).sorted(),
            awaitingAccountChoice: awaitingAccountChoice
        )
        do {
            try JSONFileStorage.write(snapshot, to: fileURL(in: directory))
        } catch {
            return
        }
    }
}

private struct Snapshot: Codable, Sendable {
    var schemaVersion: Int
    var engineState: Data?
    var systemFields: [String: Data]
    var acknowledgedDeletions: [String]
    var awaitingAccountChoice: Bool
}
