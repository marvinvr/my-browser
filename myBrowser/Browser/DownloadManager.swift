import AppKit
import Foundation
import Observation
import WebKit

/// Downloads for every profile. The popover shows the profile of the current space.
///
/// WebKit writes to `name.pdf.download` (the destination must not already exist). On finish
/// that file is renamed to `name.pdf`, then quarantine and where-from attributes are set and
/// the Downloads stack in the Dock is asked to bounce.
@Observable
final class DownloadManager {
    private(set) var records: [DownloadRecord] = []
    var visibleProfileID: UUID = UUID() {
        didSet {
            guard oldValue != visibleProfileID else { return }
            publishChrome()
        }
    }
    var isPopoverPresented = false {
        didSet { publishChrome() }
    }
    var isPagePresented = false {
        didSet {
            if isPagePresented { isPopoverPresented = false }
            publishChrome()
        }
    }
    private(set) var toolbarVisible = false
    private(set) var isDownloading = false
    /// Nil while a download's size is unknown. The button draws a moving ring in that case.
    private(set) var ringFraction: Double?

    /// A live tab's web view for this profile, so resume and retry keep that profile's cookies.
    @ObservationIgnored var webViewProvider: ((UUID) -> WKWebView?)?

    @ObservationIgnored private let bridge = DownloadDelegateBridge()
    @ObservationIgnored private let storageDirectory: URL?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var live: [UUID: LiveDownload] = [:]
    @ObservationIgnored private var objectIDs: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var stops: [UUID: Stop] = [:]
    @ObservationIgnored private var speeds: [UUID: Double] = [:]
    @ObservationIgnored private var auxiliary: [UUID: WKWebView] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var visibilityTask: Task<Void, Never>?
    @ObservationIgnored private var lastDiskWrite = Date.distantPast
    /// Keeps a web view alive after its tab closes, otherwise WebKit cancels the download.
    @ObservationIgnored private var park: NSWindow?

    init(directory: URL?) {
        storageDirectory = directory
        fileURL = directory?.appending(path: "downloads.json", directoryHint: .notDirectory)
        bridge.manager = self
        load()
    }

    // MARK: List

    var popoverRecords: [DownloadRecord] {
        DownloadList.popover(records: records, profileID: visibleProfileID, now: .now)
    }

    func history(matching query: String) -> [DownloadRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records
            .filter { $0.profileID == visibleProfileID }
            .filter { record in
                guard !needle.isEmpty else { return true }
                let host = record.sourceURL?.host()?.lowercased() ?? ""
                let source = record.sourceURL?.absoluteString.lowercased() ?? ""
                return record.filename.lowercased().contains(needle) || host.contains(needle) || source.contains(needle)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func record(_ id: UUID) -> DownloadRecord? {
        records.first { $0.id == id }
    }

    func subtitle(for record: DownloadRecord) -> String {
        switch record.state {
        case .downloading:
            let size: String
            if let total = record.totalBytes, total > 0 {
                size = "\(DownloadFormat.bytes(record.receivedBytes)) of \(DownloadFormat.bytes(total))"
            } else if record.receivedBytes > 0 {
                size = DownloadFormat.bytes(record.receivedBytes)
            } else {
                size = "Starting…"
            }
            if let speed = speeds[record.id], speed > 1 {
                return "\(size) · \(DownloadFormat.speed(speed))"
            }
            return size
        case .paused:
            if record.receivedBytes > 0 {
                return "Paused · \(DownloadFormat.bytes(record.receivedBytes))"
            }
            return "Paused"
        case .finished:
            let size = record.totalBytes ?? record.receivedBytes
            return size > 0 ? DownloadFormat.bytes(size) : "Done"
        case .failed:
            if let message = record.errorMessage, !message.isEmpty {
                return "Failed · \(message)"
            }
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    func canClearPopover() -> Bool {
        popoverRecords.contains { !$0.isActive }
    }

    // MARK: WebKit

    func adopt(_ download: WKDownload, profileID: UUID, pageURL: URL?, webView: WKWebView) {
        let key = ObjectIdentifier(download)
        if objectIDs[key] != nil { return }
        let now = Date()
        let record = DownloadRecord(
            id: UUID(),
            profileID: profileID,
            filename: "Download",
            finalURL: nil,
            partialURL: nil,
            sourceURL: download.originalRequest?.url,
            pageURL: pageURL,
            mimeType: nil,
            state: .downloading,
            receivedBytes: 0,
            totalBytes: nil,
            createdAt: now,
            updatedAt: now,
            finishedAt: nil,
            errorMessage: nil,
            resumeData: nil,
            dismissed: false
        )
        records.insert(record, at: 0)
        attach(download, id: record.id, webView: webView)
        publishChrome()
        flush()
    }

    func isDownloading(in webView: WKWebView) -> Bool {
        live.values.contains { $0.webView === webView }
    }

    /// Moves `webView` into a hidden window so closing the tab does not cancel its downloads.
    func parkIfNeeded(_ webView: WKWebView) {
        guard isDownloading(in: webView) else { return }
        let window = park ?? {
            let window = NSWindow(
                contentRect: NSRect(x: -12_000, y: -12_000, width: 4, height: 4),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            self.park = window
            return window
        }()
        window.contentView?.addSubview(webView)
    }

    func destination(for download: WKDownload, response: URLResponse, suggestedFilename: String) -> URL? {
        guard let id = objectIDs[ObjectIdentifier(download)], let index = index(of: id) else { return nil }
        if records[index].sourceURL == nil {
            records[index].sourceURL = download.originalRequest?.url ?? response.url
        }
        if let mime = response.mimeType, !mime.isEmpty {
            records[index].mimeType = mime
        }
        // Resume asks again. Hand back the same partial path when it is still absent.
        if let partial = records[index].partialURL, !Self.fileExists(partial) {
            return partial
        }
        guard let directory = downloadsDirectory() else {
            let recordID = records[index].id
            fail(index, message: "Downloads folder is unavailable.")
            dropLive(recordID)
            publishChrome()
            return nil
        }
        let suggested = suggestedFilename.isEmpty ? (response.suggestedFilename ?? "Download") : suggestedFilename
        let finalName = DownloadFilenames.uniqueFinalName(preferred: suggested, taken: takenNames(in: directory))
        let finalURL = directory.appending(path: finalName, directoryHint: .notDirectory)
        let partialURL = directory.appending(path: DownloadFilenames.partialName(forFinal: finalName), directoryHint: .notDirectory)
        records[index].filename = finalName
        records[index].finalURL = finalURL
        records[index].partialURL = partialURL
        records[index].updatedAt = Date()
        return partialURL
    }

    func finished(_ download: WKDownload) {
        guard let id = objectIDs[ObjectIdentifier(download)], let index = index(of: id) else { return }
        let record = records[index]
        let saved = publishFile(partial: record.partialURL, final: record.finalURL, progressURL: download.progress.fileURL)
        if let saved {
            DownloadQuarantine.apply(to: saved, source: record.sourceURL, page: record.pageURL)
            bounceDownloadsStack(saved)
            records[index].finalURL = saved
            records[index].filename = saved.lastPathComponent
            records[index].partialURL = nil
            records[index].state = .finished
            records[index].finishedAt = Date()
            records[index].errorMessage = nil
            records[index].resumeData = nil
            records[index].dismissed = false
            let size = Self.fileSize(saved)
            if size > 0 {
                records[index].receivedBytes = size
                records[index].totalBytes = size
            }
        } else {
            records[index].state = .failed
            records[index].errorMessage = "The file was not saved."
        }
        records[index].updatedAt = Date()
        dropLive(id)
        publishChrome()
        flush()
    }

    func failed(_ download: WKDownload, error: Error, resumeData: Data?) {
        guard let id = objectIDs[ObjectIdentifier(download)] else { return }
        // Pause and cancel both surface as a failure. The cancel completion applies the stop.
        if stops[id] != nil {
            if let resumeData, !resumeData.isEmpty, let index = index(of: id), records[index].state == .downloading {
                records[index].resumeData = resumeData
            }
            return
        }
        guard let index = index(of: id) else { return }
        if records[index].state != .downloading {
            dropLive(id)
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            records[index].state = .cancelled
            records[index].resumeData = nil
            deletePartial(records[index].partialURL)
        } else {
            records[index].state = .failed
            records[index].errorMessage = nsError.localizedDescription
            records[index].resumeData = resumeData
            if resumeData == nil {
                deletePartial(records[index].partialURL)
            }
        }
        records[index].updatedAt = Date()
        dropLive(id)
        publishChrome()
        flush()
    }

    func challengeDisposition(for challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.performDefaultHandling, nil)
    }

    // MARK: Actions

    func pause(_ id: UUID) {
        guard let entry = live[id], record(id)?.state == .downloading else { return }
        stops[id] = .pause
        entry.speed.reset()
        entry.download.cancel { [weak self] data in
            self?.applyStop(id, .pause, data)
        }
    }

    func resume(_ id: UUID) {
        guard let index = index(of: id) else { return }
        guard records[index].state == .paused || records[index].state == .failed else { return }
        guard let data = records[index].resumeData, let webView = webView(for: records[index].profileID) else {
            retry(id)
            return
        }
        records[index].state = .downloading
        records[index].errorMessage = nil
        records[index].dismissed = false
        records[index].updatedAt = Date()
        // The destination has to be absent. A leftover partial keeps its bytes under a new name.
        if let partial = records[index].partialURL, Self.fileExists(partial) {
            records[index].partialURL = nil
        }
        publishChrome()
        let resumeData = data
        webView.resumeDownload(fromResumeData: resumeData) { [weak self] download in
            self?.attach(download, id: id, webView: webView)
            self?.flush()
        }
    }

    func cancel(_ id: UUID) {
        guard record(id) != nil else { return }
        if let entry = live[id] {
            stops[id] = .cancel
            entry.download.cancel { [weak self] _ in
                self?.applyStop(id, .cancel, nil)
            }
            return
        }
        applyStop(id, .cancel, nil)
    }

    func retry(_ id: UUID) {
        guard let index = index(of: id) else { return }
        guard let source = records[index].sourceURL, let webView = webView(for: records[index].profileID) else { return }
        deletePartial(records[index].partialURL)
        records[index].state = .downloading
        records[index].receivedBytes = 0
        records[index].totalBytes = nil
        records[index].resumeData = nil
        records[index].errorMessage = nil
        records[index].dismissed = false
        records[index].finishedAt = nil
        records[index].partialURL = nil
        records[index].finalURL = nil
        records[index].updatedAt = Date()
        speeds[id] = nil
        publishChrome()
        var request = URLRequest(url: source)
        if let page = records[index].pageURL {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        }
        webView.startDownload(using: request) { [weak self] download in
            self?.attach(download, id: id, webView: webView)
            self?.flush()
        }
    }

    /// Drops finished, failed, and cancelled rows from the popover. Files and history stay.
    func clearPopover() {
        let now = Date()
        var changed = false
        for index in records.indices {
            guard records[index].profileID == visibleProfileID, !records[index].isActive, !records[index].dismissed else { continue }
            records[index].dismissed = true
            records[index].updatedAt = now
            changed = true
        }
        guard changed else { return }
        publishChrome()
        flush()
    }

    /// Removes one history row. An in-progress download is cancelled. The file in Downloads stays.
    func remove(_ id: UUID) {
        if live[id] != nil {
            stops[id] = .cancel
            live[id]?.download.cancel { _ in }
        }
        if let index = index(of: id) {
            deletePartial(records[index].partialURL)
        }
        dropLive(id)
        records.removeAll { $0.id == id }
        speeds[id] = nil
        publishChrome()
        flush()
    }

    func clearHistory() {
        let active = records.filter { $0.profileID == visibleProfileID && $0.isActive }.map(\.id)
        let removing = records.filter { $0.profileID == visibleProfileID && !active.contains($0.id) }
        for record in removing {
            deletePartial(record.partialURL)
        }
        records.removeAll { $0.profileID == visibleProfileID && !$0.isActive }
        publishChrome()
        flush()
    }

    func reveal(_ id: UUID) {
        guard let url = existingFile(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func existingFile(_ id: UUID) -> URL? {
        guard let record = record(id) else { return nil }
        if let final = record.finalURL, Self.fileExists(final) { return final }
        if let partial = record.partialURL, Self.fileExists(partial) { return partial }
        return nil
    }

    /// A hidden web view for a profile whose tabs are all unloaded.
    func auxiliaryWebView(profileID: UUID, configuration: WKWebViewConfiguration) -> WKWebView {
        if let existing = auxiliary[profileID] { return existing }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        auxiliary[profileID] = webView
        return webView
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let fileURL else { return }
        let catalog = DownloadCatalog(schemaVersion: DownloadCatalog.currentSchema, items: records)
        try? JSONFileStorage.write(catalog, to: fileURL)
        lastDiskWrite = Date()
    }

    // MARK: Progress

    func noteProgress(id: UUID, received: Int64, total: Int64?) {
        guard let index = index(of: id), records[index].state == .downloading else { return }
        let now = Date()
        if let entry = live[id] {
            speeds[id] = entry.speed.note(bytes: received, at: now)
        }
        let knownTotal = (total ?? 0) > 0 ? total : nil
        if records[index].receivedBytes == received, records[index].totalBytes == knownTotal { return }
        records[index].receivedBytes = received
        records[index].totalBytes = knownTotal
        records[index].updatedAt = now
        publishChrome()
        if now.timeIntervalSince(lastDiskWrite) > 2 {
            flush()
        }
    }

    // MARK: Private

    private enum Stop {
        case pause
        case cancel
    }

    private func load() {
        guard let fileURL, let catalog = try? JSONFileStorage.read(DownloadCatalog.self, from: fileURL) else {
            publishChrome()
            return
        }
        let restored = DownloadList.recovered(catalog.items)
        records = restored
        if restored != catalog.items {
            flush()
        }
        publishChrome()
    }

    private func webView(for profileID: UUID) -> WKWebView? {
        webViewProvider?(profileID)
    }

    private func attach(_ download: WKDownload, id: UUID, webView: WKWebView) {
        if let previous = live[id] {
            previous.observation?.invalidate()
            objectIDs.removeValue(forKey: ObjectIdentifier(previous.download))
        }
        download.delegate = bridge
        let entry = LiveDownload(id: id, download: download, webView: webView)
        live[id] = entry
        objectIDs[ObjectIdentifier(download)] = id
        let box = ManagerBox(self)
        entry.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { progress, _ in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                box.manager?.noteProgress(id: id, received: received, total: total > 0 ? total : nil)
            }
        }
        publishChrome()
    }

    private func applyStop(_ id: UUID, _ intent: Stop, _ resumeData: Data?) {
        stops[id] = nil
        guard let index = index(of: id) else {
            dropLive(id)
            return
        }
        switch intent {
        case .pause:
            guard records[index].state == .downloading || records[index].state == .paused else { break }
            records[index].state = .paused
            if let resumeData, !resumeData.isEmpty {
                records[index].resumeData = resumeData
            }
            records[index].errorMessage = nil
            records[index].dismissed = false
        case .cancel:
            guard records[index].state == .downloading || records[index].state == .paused else { break }
            records[index].state = .cancelled
            records[index].resumeData = nil
            deletePartial(records[index].partialURL)
        }
        records[index].updatedAt = Date()
        dropLive(id)
        publishChrome()
        flush()
    }

    private func dropLive(_ id: UUID) {
        if let entry = live.removeValue(forKey: id) {
            entry.observation?.invalidate()
            objectIDs.removeValue(forKey: ObjectIdentifier(entry.download))
            let webView = entry.webView
            if !isDownloading(in: webView), webView.superview === park?.contentView {
                webView.removeFromSuperview()
            }
        }
        speeds[id] = nil
    }

    func debugSummary() -> String {
        records.map { record in
            [
                record.state.rawValue,
                record.filename,
                "\(record.receivedBytes)",
                "\(record.totalBytes ?? -1)",
                record.finalURL?.path(percentEncoded: false) ?? "-",
                record.partialURL?.path(percentEncoded: false) ?? "-",
                record.profileID.uuidString,
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private func fail(_ index: Int, message: String) {
        records[index].state = .failed
        records[index].errorMessage = message
        records[index].updatedAt = Date()
        publishChrome()
    }

    private func index(of id: UUID) -> Int? {
        records.firstIndex { $0.id == id }
    }

    private func downloadsDirectory() -> URL? {
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func takenNames(in directory: URL) -> Set<String> {
        var names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
        for record in records where record.isActive {
            if let name = record.finalURL?.lastPathComponent { names.insert(name) }
            if let name = record.partialURL?.lastPathComponent { names.insert(name) }
        }
        return names
    }

    /// Move the partial onto its final name. A name that appeared while the download ran gets the next `(n)`.
    private func publishFile(partial: URL?, final: URL?, progressURL: URL?) -> URL? {
        let source: URL?
        if let partial, Self.fileExists(partial) {
            source = partial
        } else if let progressURL, Self.fileExists(progressURL) {
            source = progressURL
        } else if let final, Self.fileExists(final) {
            return final
        } else {
            return nil
        }
        guard let source else { return nil }
        guard let final else { return source }
        if source.standardizedFileURL == final.standardizedFileURL { return final }
        var destination = final
        if Self.fileExists(destination) {
            let directory = destination.deletingLastPathComponent()
            let name = DownloadFilenames.uniqueFinalName(
                preferred: destination.lastPathComponent,
                taken: takenNames(in: directory)
            )
            destination = directory.appending(path: name, directoryHint: .notDirectory)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            return Self.fileExists(source) ? source : nil
        }
    }

    private func deletePartial(_ url: URL?) {
        guard let url else { return }
        guard url.lastPathComponent.hasSuffix(".download") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The Dock bounces its Downloads stack when it hears this. The object is the finished path.
    private func bounceDownloadsStack(_ file: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"),
            object: file.path(percentEncoded: false),
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func publishChrome() {
        let now = Date()
        let visible = DownloadList.showsToolbarButton(
            records: records,
            profileID: visibleProfileID,
            now: now,
            popoverPresented: isPopoverPresented,
            pagePresented: isPagePresented
        )
        if toolbarVisible != visible { toolbarVisible = visible }
        let downloading = DownloadList.isDownloading(records: records, profileID: visibleProfileID)
        if isDownloading != downloading { isDownloading = downloading }
        let fraction = DownloadList.ringFraction(records: records, profileID: visibleProfileID)
        if ringFraction != fraction { ringFraction = fraction }
        scheduleVisibilityRefresh(now: now)
    }

    private func scheduleVisibilityRefresh(now: Date) {
        visibilityTask?.cancel()
        let dates = records.compactMap { record -> Date? in
            guard record.profileID == visibleProfileID, !record.dismissed, !record.isActive else { return nil }
            return record.updatedAt.addingTimeInterval(DownloadList.recentInterval)
        }
        guard let soonest = dates.min() else { return }
        let delay = soonest.timeIntervalSince(now)
        guard delay > 0 else { return }
        visibilityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            guard !Task.isCancelled else { return }
            self?.publishChrome()
        }
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

private final class LiveDownload {
    let id: UUID
    let download: WKDownload
    let webView: WKWebView
    var observation: NSKeyValueObservation?
    let speed = DownloadSpeed()

    init(id: UUID, download: WKDownload, webView: WKWebView) {
        self.id = id
        self.download = download
        self.webView = webView
    }
}

private final class DownloadSpeed {
    private var samples: [(date: Date, bytes: Int64)] = []

    func note(bytes: Int64, at date: Date) -> Double? {
        samples.append((date, bytes))
        samples.removeAll { date.timeIntervalSince($0.date) > 4 }
        guard let first = samples.first, samples.count >= 2 else { return nil }
        let elapsed = date.timeIntervalSince(first.date)
        guard elapsed >= 0.35 else { return nil }
        let delta = Double(bytes - first.bytes)
        guard delta >= 0 else { return nil }
        return delta / elapsed
    }

    func reset() {
        samples.removeAll()
    }
}

private final class ManagerBox: @unchecked Sendable {
    weak var manager: DownloadManager?
    init(_ manager: DownloadManager) { self.manager = manager }
}

/// `WKDownloadDelegate` needs `NSObject`. The manager stays an observable class.
private final class DownloadDelegateBridge: NSObject, WKDownloadDelegate {
    weak var manager: DownloadManager?

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        manager?.destination(for: download, response: response, suggestedFilename: suggestedFilename)
    }

    func download(
        _ download: WKDownload,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        manager?.challengeDisposition(for: challenge) ?? (.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        manager?.finished(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        manager?.failed(download, error: error, resumeData: resumeData)
    }
}
