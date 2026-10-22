import AppKit
import Foundation

/// Starts iCloud sync only when the user flag, the container key, and an iCloud account are all present.
/// Otherwise it does not create a `CKContainer` or a `CKSyncEngine`.
final class SyncController {
    static let enabledDefaultsKey = "iCloudSyncEnabled"
    static let containerInfoKey = "MBCloudKitContainer"

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

    private let library: LibraryStore
    private var engine: SyncEngine?
    private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?
    private nonisolated(unsafe) var identityObserver: NSObjectProtocol?

    init(library: LibraryStore) {
        self.library = library
        startIfEnabled()
        let restart: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.startIfEnabled()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main,
            using: restart
        )
        identityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main,
            using: restart
        )
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let identityObserver {
            NotificationCenter.default.removeObserver(identityObserver)
        }
    }

    /// Flag first. The container key and the iCloud account are only consulted when the flag is on.
    func startIfEnabled() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        guard enabled else {
            engine?.stop()
            return
        }
        guard let identifier = Self.containerIdentifier else {
            engine?.stop()
            return
        }
        guard FileManager.default.ubiquityIdentityToken != nil else { return }
        if engine == nil {
            let created = SyncEngine(library: library, containerIdentifier: identifier)
            created.resolveAccountSwitch = { [weak self] in
                self?.askAccountSwitch() ?? .turnOff
            }
            created.onTurnOff = {
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            }
            engine = created
        }
        engine?.start()
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
