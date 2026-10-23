import CloudKit
import Foundation
import os

/// Wraps `CKSyncEngine` for the private `Library` zone.
/// Created only by `SyncController` after the flag, container key, and iCloud account all pass.
@MainActor
final class SyncEngine: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    var resolveAccountSwitch: (() -> SyncController.AccountChoice)?
    var onTurnOff: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private static let log = Logger(subsystem: "ch.marvinvr.mybrowser", category: "Sync")

    private let library: LibraryStore
    private let state: SyncState
    private let containerIdentifier: String
    private var ck: CKSyncEngine?
    private var installedHandler = false
    private var forwardedOnChange: ((Set<UUID>) -> Void)?
    private var choosingAccount = false
    /// A fetch or save has started. A caught-up launch never does either, and the footer would stay on "Syncing…".
    private var sawSyncCycle = false
    /// A save failed and was not retried. Later fetch/send events must not replace the paused footer.
    private var syncPaused = false
    /// First sync of an untouched Personal placeholder. Its records stay local until the fetch
    /// shows whether iCloud already has spaces. Ids are captured before the fetch adds spaces.
    private var withholdPlaceholder = false
    private var withheldPlaceholderIDs: Set<UUID> = []

    init(library: LibraryStore, containerIdentifier: String) {
        self.library = library
        self.containerIdentifier = containerIdentifier
        self.state = SyncState(directory: library.directory)
        super.init()
    }

    func start() {
        if state.awaitingAccountChoice {
            resolvePendingAccountChoice()
            return
        }
        guard ck == nil else { return }
        let container = CKContainer(identifier: containerIdentifier)
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: state.serialization(),
            delegate: self
        )
        ck = CKSyncEngine(configuration)
        installHandler()
        let firstSync = state.serialization() == nil
        if firstSync {
            beginFirstSync()
        }
        forgetPurged(library.purgeAcknowledgedTombstones(sent: state.acknowledgedDeletions))
        scheduleIdleIfQuiet()
    }

    /// Uploads an existing library immediately. A placeholder-only library waits for the fetch:
    /// the zone is created, and the Personal space is uploaded only if iCloud has no spaces.
    private func beginFirstSync() {
        let placeholder = library.untouchedPlaceholderIDs
        if !placeholder.isEmpty {
            withholdPlaceholder = true
            withheldPlaceholderIDs = placeholder
            ck?.state.add(pendingDatabaseChanges: [.saveZone(SyncSchema.zone)])
            Self.log.info("Queued Library zone save")
            sawSyncCycle = true
            return
        }
        enqueueFullUpload()
        sawSyncCycle = true
    }

    /// CKSyncEngine skips the fetch when the change token is current and nothing is pending.
    /// That posts no did-fetch event, so settle the footer once it is clear nothing will start.
    private func scheduleIdleIfQuiet() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !withholdPlaceholder, !sawSyncCycle, let ck else { return }
            settle(ck)
        }
    }

    private func hasPendingWork(_ syncEngine: CKSyncEngine) -> Bool {
        !syncEngine.state.pendingRecordZoneChanges.isEmpty
            || !syncEngine.state.pendingDatabaseChanges.isEmpty
    }

    private func settle(_ syncEngine: CKSyncEngine) {
        let text = SyncActivityStatus.text(paused: syncPaused, hasPendingChanges: hasPendingWork(syncEngine) || withholdPlaceholder)
        onStatus?(text)
        if text == SyncController.idleStatus {
            Self.log.info("Sync idle")
        }
    }

    /// The fetch has landed. Drop the placeholder when iCloud already has spaces; otherwise upload it.
    private func resolvePlaceholderAfterFetch(_ syncEngine: CKSyncEngine) {
        guard withholdPlaceholder else { return }
        withholdPlaceholder = false
        let ids = withheldPlaceholderIDs
        withheldPlaceholderIDs = []
        guard library.placeholderStillUntouched(ids) else {
            enqueueFullUpload()
            return
        }
        let live = Set(library.spaces.values.filter { $0.deletedAt == nil }.map(\.id))
        switch PlaceholderSync.afterFetch(placeholderIDs: ids, liveSpaceIDs: live) {
        case .drop:
            let removed = library.discardPlaceholder(ids)
            removePending(removed, syncEngine: syncEngine)
            Self.log.info("Dropped untouched placeholder")
        case .upload:
            enqueue(ids)
        }
    }

    private func removePending(_ ids: Set<UUID>, syncEngine: CKSyncEngine) {
        guard !ids.isEmpty else { return }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                guard let id = UUID(uuidString: recordID.recordName) else { return false }
                return ids.contains(id)
            @unknown default:
                return false
            }
        }
        if !pending.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: pending)
        }
    }

    func stop(resetting: Bool = false) {
        ck = nil
        removeHandler()
        if resetting {
            state.reset()
        }
    }

    func enqueue(_ ids: Set<UUID>) {
        guard let ck, !ids.isEmpty else { return }
        var ids = ids
        if withholdPlaceholder {
            ids.subtract(withheldPlaceholderIDs)
        }
        guard !ids.isEmpty else { return }
        let changes = library.pendingChanges(for: ids).map { change -> CKSyncEngine.PendingRecordZoneChange in
            let recordID = SyncSchema.recordID(for: change.id)
            switch change {
            case .save: return .saveRecord(recordID)
            case .delete: return .deleteRecord(recordID)
            }
        }
        guard !changes.isEmpty else { return }
        ck.state.add(pendingRecordZoneChanges: changes)
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await apply(event, syncEngine: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await makeBatch(context, syncEngine: syncEngine)
    }

    private func apply(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        state.performBatch {
            switch event {
            case .stateUpdate(let update):
                state.setSerialization(update.stateSerialization)
            case .accountChange(let change):
                handleAccount(change, syncEngine: syncEngine)
            case .fetchedDatabaseChanges(let changes):
                handleFetchedDatabase(changes)
            case .fetchedRecordZoneChanges(let changes):
                handleFetchedRecords(changes, syncEngine: syncEngine)
            case .sentRecordZoneChanges(let changes):
                handleSentRecords(changes, syncEngine: syncEngine)
            case .didFetchRecordZoneChanges(let fetched):
                handleZoneFetchFinished(fetched, syncEngine: syncEngine)
            case .willFetchChanges, .willFetchRecordZoneChanges, .willSendChanges:
                sawSyncCycle = true
                if !syncPaused {
                    onStatus?(SyncController.syncingStatus)
                }
            case .didFetchChanges:
                sawSyncCycle = true
                resolvePlaceholderAfterFetch(syncEngine)
                settle(syncEngine)
            case .didSendChanges:
                sawSyncCycle = true
                settle(syncEngine)
            case .sentDatabaseChanges:
                settle(syncEngine)
            @unknown default:
                break
            }
        }
    }

    private func handleAccount(_ change: CKSyncEngine.Event.AccountChange, syncEngine: CKSyncEngine) {
        switch change.changeType {
        case .signOut:
            Self.log.info("iCloud account signed out")
            onStatus?(SyncController.signedOutStatus)
            Task { @MainActor in
                self.stop(resetting: true)
            }
        case .signIn:
            if state.systemFields.isEmpty {
                // beginFirstSync already captured the placeholder. Re-reading it after a fetch
                // sees the remote spaces and would upload the placeholder.
                if !withholdPlaceholder {
                    let placeholder = library.untouchedPlaceholderIDs
                    if state.serialization() == nil && !placeholder.isEmpty {
                        withholdPlaceholder = true
                        withheldPlaceholderIDs = placeholder
                    } else {
                        enqueueFullUpload()
                        sawSyncCycle = true
                    }
                }
            } else {
                settle(syncEngine)
            }
        case .switchAccounts:
            dropPending()
            state.reset(awaitingAccountChoice: true)
            Task { @MainActor in
                self.resolvePendingAccountChoice()
            }
        @unknown default:
            break
        }
    }

    private func resolvePendingAccountChoice() {
        guard !choosingAccount else { return }
        choosingAccount = true
        defer { choosingAccount = false }
        let choice = resolveAccountSwitch?() ?? .turnOff
        state.setAwaitingAccountChoice(false)
        switch choice {
        case .sync:
            stop()
            start()
            enqueueFullUpload()
        case .turnOff:
            stop(resetting: true)
            onTurnOff?()
        }
    }

    private func handleFetchedDatabase(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        let lostZone = changes.deletions.contains { deletion in
            guard deletion.zoneID.zoneName == SyncSchema.zoneName else { return false }
            switch deletion.reason {
            case .deleted, .purged, .encryptedDataReset:
                return true
            @unknown default:
                return true
            }
        }
        guard lostZone else { return }
        state.clearSystemFields()
        withholdPlaceholder = false
        withheldPlaceholderIDs = []
        enqueueFullUpload()
    }

    private func handleZoneFetchFinished(
        _ fetched: CKSyncEngine.Event.DidFetchRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        guard fetched.zoneID.zoneName == SyncSchema.zoneName, let error = fetched.error else { return }
        switch error.code {
        case .zoneNotFound, .userDeletedZone:
            state.clearSystemFields()
            withholdPlaceholder = false
            withheldPlaceholderIDs = []
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(SyncSchema.zone)])
            enqueueFullUpload()
        default:
            break
        }
    }

    private func handleFetchedRecords(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        var update = RemoteLibraryUpdate()
        var deletions = Set<UUID>()
        var upload: [CKSyncEngine.PendingRecordZoneChange] = []

        for modification in changes.modifications {
            let record = modification.record
            guard let id = UUID(uuidString: record.recordID.recordName) else { continue }
            state.setSystemFields(RecordSystemFields.encode(record), for: id)
            guard let serverSide = RecordMapper.side(of: record),
                  let mapped = RecordMapper.decode(record) else { continue }
            switch SyncConflict.merge(local: library.syncSide(for: id), server: serverSide) {
            case .applyServer:
                append(mapped, to: &update)
                if serverSide.isDeleted {
                    state.markDeletionSent([id])
                }
            case .uploadLocal:
                let deleted = library.syncSide(for: id)?.isDeleted == true
                upload.append(deleted ? .deleteRecord(record.recordID) : .saveRecord(record.recordID))
            }
        }

        for deletion in changes.deletions {
            guard let id = UUID(uuidString: deletion.recordID.recordName) else { continue }
            if library.items[id]?.section == .tabs { continue }
            deletions.insert(id)
            state.removeSystemFields(for: id)
        }

        Self.log.info("Fetched \(changes.modifications.count, privacy: .public) records, \(changes.deletions.count, privacy: .public) deletions")
        library.applyRemote(upserts: update, deletions: deletions)
        if !upload.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: upload)
        }
        forgetPurged(library.purgeAcknowledgedTombstones(sent: state.acknowledgedDeletions))
    }

    private func handleSentRecords(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        Self.log.info("Sent \(changes.savedRecords.count, privacy: .public) saves, \(changes.deletedRecordIDs.count, privacy: .public) deletes, \(changes.failedRecordSaves.count, privacy: .public) failed saves")
        for record in changes.savedRecords {
            guard let id = UUID(uuidString: record.recordID.recordName) else { continue }
            state.setSystemFields(RecordSystemFields.encode(record), for: id)
        }
        for recordID in changes.deletedRecordIDs {
            noteServerDeletion(recordID)
        }
        for (recordID, error) in changes.failedRecordDeletes where error.code == .unknownItem {
            noteServerDeletion(recordID)
        }
        for failure in changes.failedRecordSaves {
            handleFailedSave(failure, syncEngine: syncEngine)
        }
        if changes.failedRecordSaves.isEmpty {
            syncPaused = false
        }
        forgetPurged(library.purgeAcknowledgedTombstones(sent: state.acknowledgedDeletions))
    }

    private func handleFailedSave(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) {
        let recordID = failure.record.recordID
        guard let id = UUID(uuidString: recordID.recordName) else { return }
        let error = failure.error
        if error.code == .serverRecordChanged, let server = error.serverRecord {
            state.setSystemFields(RecordSystemFields.encode(server), for: id)
            guard let serverSide = RecordMapper.side(of: server) else { return }
            switch SyncConflict.merge(local: library.syncSide(for: id), server: serverSide) {
            case .applyServer:
                apply(server)
                if serverSide.isDeleted {
                    state.markDeletionSent([id])
                }
            case .uploadLocal:
                let deleted = library.syncSide(for: id)?.isDeleted == true
                let change: CKSyncEngine.PendingRecordZoneChange = deleted ? .deleteRecord(recordID) : .saveRecord(recordID)
                syncEngine.state.add(pendingRecordZoneChanges: [change])
            }
            return
        }

        guard error.code == .unknownItem || error.code == .zoneNotFound else {
            Self.log.error("Save failed \(error.code.rawValue, privacy: .public)")
            syncPaused = true
            onStatus?(SyncController.pausedStatus)
            return
        }
        let outcome = SyncConflict.resolveMissingServerRecord(
            local: library.syncSide(for: id),
            lastKnownServerModification: modificationDate(inSystemFieldsFor: id)
        )
        switch outcome {
        case .recreateLocal:
            state.removeSystemFields(for: id)
            if error.code == .zoneNotFound {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(SyncSchema.zone)])
            }
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .dropLocal:
            library.applyRemote(upserts: RemoteLibraryUpdate(), deletions: [id])
            state.removeSystemFields(for: id)
        case .deletionAlreadyDone:
            state.removeSystemFields(for: id)
            state.markDeletionSent([id])
        }
    }

    private func makeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = preparePending(scope: context.options.scope, syncEngine: syncEngine)
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.recordForSave(recordID)
        }
    }

    private func preparePending(
        scope: CKSyncEngine.SendChangesOptions.Scope,
        syncEngine: CKSyncEngine
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        var drop: [CKSyncEngine.PendingRecordZoneChange] = []
        var extraDeletes: [CKSyncEngine.PendingRecordZoneChange] = []
        var keep: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in syncEngine.state.pendingRecordZoneChanges {
            guard scope.contains(change) else { continue }
            switch change {
            case .saveRecord(let recordID):
                if recordForSave(recordID) != nil {
                    keep.append(change)
                } else if shouldDelete(recordID) {
                    drop.append(change)
                    let deletion = CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID)
                    extraDeletes.append(deletion)
                    if scope.contains(deletion) {
                        keep.append(deletion)
                    }
                } else {
                    drop.append(change)
                }
            case .deleteRecord:
                keep.append(change)
            @unknown default:
                keep.append(change)
            }
        }
        if !drop.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: drop)
        }
        if !extraDeletes.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: extraDeletes)
        }
        return keep
    }

    private func recordForSave(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let id = UUID(uuidString: recordID.recordName) else { return nil }
        let fields = state.systemFields(for: id)
        if let profile = library.profiles[id], profile.deletedAt == nil {
            return RecordMapper.record(for: profile, systemFields: fields)
        }
        if let space = library.spaces[id], space.deletedAt == nil {
            return RecordMapper.record(for: space, systemFields: fields)
        }
        if let item = library.items[id], item.isSynced, item.deletedAt == nil {
            return RecordMapper.record(for: item, systemFields: fields)
        }
        return nil
    }

    private func shouldDelete(_ recordID: CKRecord.ID) -> Bool {
        guard let id = UUID(uuidString: recordID.recordName) else { return false }
        return library.syncSide(for: id)?.isDeleted == true
    }

    private func enqueueFullUpload() {
        guard let ck else { return }
        ck.state.add(pendingDatabaseChanges: [.saveZone(SyncSchema.zone)])
        Self.log.info("Queued Library zone save")
        let ids = Set(library.profiles.keys)
            .union(library.spaces.keys)
            .union(library.items.keys)
        enqueue(ids)
    }

    private func dropPending() {
        guard let ck else { return }
        let records = ck.state.pendingRecordZoneChanges
        let zones = ck.state.pendingDatabaseChanges
        if !records.isEmpty {
            ck.state.remove(pendingRecordZoneChanges: records)
        }
        if !zones.isEmpty {
            ck.state.remove(pendingDatabaseChanges: zones)
        }
    }

    private func apply(_ record: CKRecord) {
        guard let mapped = RecordMapper.decode(record) else { return }
        var update = RemoteLibraryUpdate()
        append(mapped, to: &update)
        library.applyRemote(upserts: update, deletions: [])
    }

    private func append(_ mapped: MappedRecord, to update: inout RemoteLibraryUpdate) {
        switch mapped {
        case .profile(let profile): update.profiles.append(profile)
        case .space(let space): update.spaces.append(space)
        case .item(let item): update.items.append(item)
        }
    }

    private func noteServerDeletion(_ recordID: CKRecord.ID) {
        guard let id = UUID(uuidString: recordID.recordName) else { return }
        let tombstoneRemains = library.syncSide(for: id)?.isDeleted == true
        state.removeSystemFields(for: id)
        if tombstoneRemains {
            state.markDeletionSent([id])
        }
    }

    private func modificationDate(inSystemFieldsFor id: UUID) -> Date? {
        guard let data = state.systemFields(for: id),
              let record = RecordSystemFields.decode(data) else { return nil }
        return record.modificationDate
    }

    private func forgetPurged(_ ids: Set<UUID>) {
        state.removeAcknowledgedDeletions(ids)
    }

    private func installHandler() {
        guard !installedHandler else { return }
        forwardedOnChange = library.onChange
        installedHandler = true
        library.onChange = { [weak self] ids in
            self?.forwardedOnChange?(ids)
            self?.enqueue(ids)
        }
    }

    private func removeHandler() {
        guard installedHandler else { return }
        library.onChange = forwardedOnChange
        forwardedOnChange = nil
        installedHandler = false
    }
}
