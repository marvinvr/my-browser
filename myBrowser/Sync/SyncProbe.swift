import Foundation

/// Throws away a library through `MYBROWSER_SYNC_PROBE` so a Release build can upload, edit, and restore.
/// Inert unless that variable is a directory path.
/// `MYBROWSER_SYNC_PROBE_MODE=scenario` renames a space, nests and collapses a folder, sets a pinned home URL,
/// builds a vertical split with unequal shares, and deletes an item.
/// `MYBROWSER_SYNC_PROBE_MODE=cleanup` deletes every space and waits for the push.
enum SyncProbe {
    static let selectItem = Notification.Name("MBSyncProbeSelectItem")

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
            writeTimeout(directory, stage: "initial", status: controller.statusText)
            return
        }
        if mode == "cleanup" {
            for space in library.orderedSpaces {
                library.deleteSpace(space.id)
            }
            let cleaned = await waitForIdle(controller, requireSyncing: true)
            try? await Task.sleep(for: .milliseconds(800))
            if cleaned {
                write(directory, #"{"phase":"cleaned"}"#)
            } else {
                writeTimeout(directory, stage: "cleanup", status: controller.statusText)
            }
            return
        }
        if mode == "scenario" {
            await runScenario(controller: controller, library: library, directory: directory)
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

    /// Edits a library that was already uploaded: rename, nest, collapse, home URL, vertical split, delete.
    private static func runScenario(controller: SyncController, library: LibraryStore, directory: URL) async {
        guard await waitForIdle(controller, requireSyncing: false) else {
            writeTimeout(directory, stage: "initial", status: controller.statusText)
            return
        }
        guard let space = library.orderedSpaces.first else {
            write(directory, #"{"phase":"empty"}"#)
            return
        }
        library.updateSpace(space.id) { $0.name = "Day Trip" }

        let folder = live(library, title: "Trips", kind: .folder)
            ?? library.addItem(spaceID: space.id, section: .pinned, kind: .folder, title: "Trips")
        let maps = live(library, title: "Maps", kind: .site)
            ?? library.addItem(
                spaceID: space.id,
                section: .pinned,
                title: "Maps",
                url: URL(string: "https://example.com/maps")
            )
        library.moveItem(maps.id, to: .pinned, parentID: folder.id)
        library.updateItem(folder.id) { $0.isExpanded = false }

        let left = live(library, title: "Left", kind: .site)
            ?? library.addItem(
                spaceID: space.id,
                section: .pinned,
                title: "Left",
                url: URL(string: "https://example.com/left")
            )
        library.updateItem(left.id) { $0.url = URL(string: "https://example.com/left/home") }
        let right = live(library, title: "Right", kind: .site)
            ?? library.addItem(
                spaceID: space.id,
                section: .pinned,
                title: "Right",
                url: URL(string: "https://example.com/right")
            )
        guard let split = library.createSplit(tabIDs: [left.id, right.id], axis: .vertical) else {
            write(directory, #"{"phase":"split-failed"}"#)
            return
        }
        library.setFractions(splitID: split.id, [0.25, 0.75])
        let gone = live(library, title: "Gone", kind: .site)
        if let gone {
            library.deleteItem(gone.id)
        }
        NotificationCenter.default.post(
            name: selectItem,
            object: nil,
            userInfo: ["id": split.id.uuidString]
        )

        let synced = await waitForIdle(controller, requireSyncing: true)
        try? await Task.sleep(for: .milliseconds(800))
        let members = library.splitMembers(of: split.id)
        let fractions = members.map { String($0.splitFraction ?? -1) }.joined(separator: ",")
        let tombstone = gone.map { library.items[$0.id]?.deletedAt != nil } ?? false
        let phase = synced ? "scenario" : "timeout"
        let body = """
        {"phase":"\(phase)","spaceID":"\(space.id.uuidString)","spaceName":"\(library.space(space.id)?.name ?? "")","folderID":"\(folder.id.uuidString)","folderExpanded":\(library.item(folder.id)?.isExpanded == true),"movedID":"\(maps.id.uuidString)","movedParent":"\(library.item(maps.id)?.parentID?.uuidString ?? "")","homeURL":"\(library.item(left.id)?.url?.absoluteString ?? "")","splitID":"\(split.id.uuidString)","splitAxis":"\(library.item(split.id)?.splitAxis?.rawValue ?? "nil")","fractions":[\(fractions)],"deletedID":"\(gone?.id.uuidString ?? "")","goneTombstone":\(tombstone)}
        """
        write(directory, body)
    }

    private static func live(_ library: LibraryStore, title: String, kind: SidebarItem.Kind) -> SidebarItem? {
        library.items.values.first { item in
            item.deletedAt == nil && item.title == title && item.kind == kind && item.section != .tabs
        }
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

    private static func writeTimeout(_ directory: URL, stage: String, status: String) {
        let safe = status
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        write(directory, "{\"phase\":\"timeout\",\"stage\":\"\(stage)\",\"status\":\"\(safe)\"}")
    }
}
