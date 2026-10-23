import AppKit
import Foundation
import Observation
import os

/// Starts iCloud sync only when the user flag, the container key, and an iCloud account are all present.
/// Otherwise it does not create a `CKContainer` or a `CKSyncEngine`.
@Observable
final class SyncController {
    static let enabledDefaultsKey = "iCloudSyncEnabled"
    static let containerInfoKey = "MBCloudKitContainer"
    static let signedOutStatus = "iCloud account is signed out. Sync is off."
    static let syncingStatus = "Syncing with iCloud…"
    static let idleStatus = "Up to date."
    static let pausedStatus = "Sync paused. Will retry."
    static let offStatus = "Sync is off on this Mac."

    private static let log = Logger(subsystem: "ch.marvinvr.mybrowser", category: "Sync")

    enum AccountChoice: Sendable {
        case sync
        case turnOff
    }

    /// Info.plist `MBCloudKitContainer`, trimmed. Absent until the iCloud container is provisioned.
    static var containerIdentifier: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: containerInfoKey) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var isContainerConfigured: Bool { containerIdentifier != nil }

    static func shouldStart(enabled: Bool, containerIdentifier: String?, hasAccount: Bool) -> Bool {
        guard enabled, hasAccount else { return false }
        guard let containerIdentifier else { return false }
        return !containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Settings footer. Empty when the container is not configured.
    private(set) var statusText = ""

    private let library: LibraryStore
    private var engine: SyncEngine?
    private var probeStarted = false
    /// Nonisolated so `deinit` can remove the observers. The box is only touched on the main actor and in `deinit`.
    private nonisolated let observers = SyncObserverBox()

    init(library: LibraryStore) {
        self.library = library
        if Self.isContainerConfigured, UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        }
        startIfEnabled()
        let restart: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.startIfEnabled()
            }
        }
        observers.defaults = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main,
            using: restart
        )
        observers.identity = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main,
            using: restart
        )
    }

    deinit {
        if let defaults = observers.defaults {
            NotificationCenter.default.removeObserver(defaults)
        }
        if let identity = observers.identity {
            NotificationCenter.default.removeObserver(identity)
        }
    }

    /// Flag first. The container key and the iCloud account are only consulted when the flag is on.
    func startIfEnabled() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        guard enabled else {
            engine?.stop()
            engine = nil
            statusText = Self.isContainerConfigured ? Self.offStatus : ""
            return
        }
        guard let identifier = Self.containerIdentifier else {
            engine?.stop()
            engine = nil
            statusText = ""
            return
        }
        if Self.forcedSignedOut || FileManager.default.ubiquityIdentityToken == nil {
            let hadEngine = engine != nil
            engine?.stop(resetting: hadEngine)
            engine = nil
            statusText = Self.signedOutStatus
            Self.log.info("Sync off: no iCloud account")
            return
        }
        guard engine == nil else { return }
        let created = SyncEngine(library: library, containerIdentifier: identifier)
        created.resolveAccountSwitch = { [weak self] in
            self?.askAccountSwitch() ?? .turnOff
        }
        created.onTurnOff = {
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        }
        created.onStatus = { [weak self] text in
            self?.statusText = text
        }
        engine = created
        statusText = Self.syncingStatus
        created.start()
        startProbeIfRequested()
    }

    /// `MYBROWSER_SYNC_FORCE_SIGNED_OUT=1` exercises the signed-out gate without signing the Mac out.
    private static var forcedSignedOut: Bool {
        ProcessInfo.processInfo.environment["MYBROWSER_SYNC_FORCE_SIGNED_OUT"] == "1"
    }

    private func startProbeIfRequested() {
        guard !probeStarted, SyncProbe.isRequested else { return }
        probeStarted = true
        let library = self.library
        Task { @MainActor in
            await SyncProbe.run(controller: self, library: library)
        }
    }

    private func askAccountSwitch() -> AccountChoice {
        let alert = NSAlert()
        alert.messageText = "Sync with this iCloud account?"
        alert.informativeText = "The iCloud account changed. Sync this library with the new account, or turn iCloud Sync off. Bookmarks on this Mac stay either way."
        alert.addButton(withTitle: "Sync")
        alert.addButton(withTitle: "Turn Off")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .sync : .turnOff
    }
}

/// Holds notification tokens so `SyncController.deinit` can remove them without touching main-actor state.
private nonisolated final class SyncObserverBox: @unchecked Sendable {
    var defaults: NSObjectProtocol?
    var identity: NSObjectProtocol?
}
