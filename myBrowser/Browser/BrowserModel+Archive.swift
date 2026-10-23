import AppKit
import Foundation

extension BrowserModel {
    /// Unit tests host the app, and a sweep there would archive the real library.
    static var runsArchiveMonitor: Bool {
        let env = ProcessInfo.processInfo.environment
        if env.keys.contains(where: { $0.hasPrefix("XCTest") }) { return false }
        if env["MYBROWSER_DISABLE_ARCHIVE"] == "1" { return false }
        let args = ProcessInfo.processInfo.arguments.joined(separator: " ")
        if args.contains("XCTest") || args.contains("xctest") { return false }
        if NSClassFromString("XCTestCase") != nil { return false }
        if Bundle.allBundles.contains(where: { $0.bundlePath.contains("myBrowserTests.xctest") }) { return false }
        return true
    }

    /// Checks every space on a timer, and again when the app becomes active.
    /// The first pass runs at launch. Tests call `archiveInactiveTabs` directly.
    func startArchiveMonitoring() {
        guard Self.runsArchiveMonitor, archiveObservers.isEmpty else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.archiveInactiveTabsUpdatingMedia()
            }
        }
        archiveObservers.append(token)
        archiveLoop = Task { @MainActor [weak self] in
            await self?.archiveInactiveTabsUpdatingMedia()
            while !Task.isCancelled {
                try? await Task.sleep(for: TabArchivePolicy.checkInterval)
                guard !Task.isCancelled else { return }
                await self?.archiveInactiveTabsUpdatingMedia()
            }
        }
    }

    func archiveInactiveTabsUpdatingMedia(now: Date = .now) async {
        await refreshArchiveMediaState()
        archiveInactiveTabs(now: now)
    }

    /// Closes stale unpinned tabs into the archive.
    /// `now` and `interval` are injected by tests. A nil interval reads Settings.
    func archiveInactiveTabs(now: Date = .now, interval: TabArchiveInterval? = nil) {
        session.pruneArchivedTabs(now: now) { [library] spaceID in
            library.space(spaceID) != nil
        }
        // A tab with no stamp has never been recorded. Stamp it now so the upgrade
        // that introduces archiving does not close the whole list on the first sweep.
        seedMissingActivity(now: now)
        let resolved = interval ?? TabArchiveInterval.current
        guard let duration = resolved.duration else { return }

        let selected = Set(session.selectedItemBySpace.values)
        let candidates = library.items.values.compactMap { item -> TabArchiveCandidate? in
            guard item.deletedAt == nil else { return nil }
            let tab = tabs[item.id]
            return TabArchiveCandidate(
                id: item.id,
                section: item.section,
                kind: item.kind,
                lastActiveAt: session.lastActiveAt[item.id],
                isSelected: selected.contains(item.id) || item.parentID.map { selected.contains($0) } == true,
                isPlayingMedia: tab?.isPlayingMedia == true || tab?.hasPictureInPictureVideo == true,
                isPictureInPicture: pictureInPictureTabID == item.id || tab?.isPictureInPictureActive == true,
                hasActiveDownload: tab?.hasActiveDownload == true
            )
        }
        for id in TabArchivePolicy.idsToArchive(candidates, interval: duration, now: now) {
            close(id, archivingAt: now)
        }
    }

    private func seedMissingActivity(now: Date) {
        var stamps = session.lastActiveAt
        var changed = false
        for item in library.items.values where item.deletedAt == nil && item.section == .tabs && item.kind == .site {
            guard stamps[item.id] == nil else { continue }
            stamps[item.id] = now
            changed = true
        }
        if changed {
            session.lastActiveAt = stamps
        }
    }

    private func refreshArchiveMediaState() async {
        for id in Array(tabs.keys) {
            await tabs[id]?.refreshMediaPlaybackState()
        }
    }
}
