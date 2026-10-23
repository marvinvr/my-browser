import Foundation

/// Throws away a library through `MYBROWSER_SYNC_PROBE` so a Release build can upload, edit, and restore.
/// Inert unless that variable is a directory path. `MYBROWSER_SYNC_PROBE_MODE=cleanup` deletes every space and waits for the push.
enum SyncProbe {
    static var isRequested: Bool { directory != nil }

    private static var directory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["MYBROWSER_SYNC_PROBE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private static var mode: String {
        let raw = ProcessInfo.processInfo.environment["MYBROWSER_SYNC_PROBE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "mutate" : raw
    }

    static func run(controller: SyncController, library: LibraryStore) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard await waitForIdle(controller, requireSyncing: false) else {
            write(directory, #"{"phase":"timeout","stage":"initial"}"#)
            return
        }
        if mode == "cleanup" {
            for space in library.orderedSpaces {
                library.deleteSpace(space.id)
            }
            let cleaned = await waitForIdle(controller, requireSyncing: true)
            try? await Task.sleep(for: .milliseconds(800))
            write(directory, cleaned ? #"{"phase":"cleaned"}"# : #"{"phase":"timeout","stage":"cleanup"}"#)
            return
        }

        guard let space = library.orderedSpaces.first else {
            write(directory, #"{"phase":"empty"}"#)
            return
        }
        library.updateSpace(space.id) { $0.name = "Sync Probe" }
        let drop = library.addItem(
            spaceID: space.id,
            section: .pinned,
            title: "Probe Drop",
            url: URL(string: "https://example.com/drop")
        )
        let keep = library.addItem(
            spaceID: space.id,
            section: .pinned,
            title: "Probe Keep",
            url: URL(string: "https://example.com/keep")
        )
        library.moveItem(keep.id, to: .pinned, parentID: nil, at: .before(drop.id))
        library.deleteItem(drop.id)
        let synced = await waitForIdle(controller, requireSyncing: true)
        try? await Task.sleep(for: .milliseconds(800))
        let phase = synced ? "mutated" : "timeout"
        let body = """
        {"phase":"\(phase)","space":"Sync Probe","kept":"Probe Keep","dropped":"Probe Drop","spaceID":"\(space.id.uuidString)","keepID":"\(keep.id.uuidString)"}
        """
        write(directory, body)
    }

    /// `requireSyncing` waits until a send starts, then until the status stays idle.
    private static func waitForIdle(_ controller: SyncController, requireSyncing: Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        var sawSyncing = false
        while clock.now < deadline {
            let text = controller.statusText
            if text == SyncController.signedOutStatus { return false }
            if text == SyncController.syncingStatus { sawSyncing = true }
            let idle = text == SyncController.idleStatus
            if idle && (sawSyncing || !requireSyncing) {
                try? await Task.sleep(for: .seconds(2))
                if controller.statusText == SyncController.idleStatus { return true }
                sawSyncing = controller.statusText == SyncController.syncingStatus
                continue
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private static func write(_ directory: URL, _ body: String) {
        let url = directory.appending(path: "probe-result.json")
        try? Data(body.utf8).write(to: url, options: .atomic)
    }
}
