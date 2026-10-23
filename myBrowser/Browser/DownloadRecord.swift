import Foundation

/// One download in the popover and on the downloads page. Local to this Mac.
nonisolated struct DownloadRecord: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var profileID: UUID
    var filename: String
    var finalURL: URL?
    var partialURL: URL?
    var sourceURL: URL?
    var pageURL: URL?
    var mimeType: String?
    var state: DownloadState
    var receivedBytes: Int64
    var totalBytes: Int64?
    var createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var errorMessage: String?
    /// Produced by `WKDownload.cancel`. Resume uses it with the same profile's data store.
    var resumeData: Data?
    /// Hidden from the toolbar popover. The downloads page still lists it.
    var dismissed: Bool

    var isActive: Bool { state == .downloading || state == .paused }

    var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(total))
    }
}

nonisolated enum DownloadState: String, Codable, Sendable, Equatable {
    case downloading
    case paused
    case finished
    case failed
    case cancelled
}

nonisolated struct DownloadCatalog: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var items: [DownloadRecord]

    static let currentSchema = 1
}

/// Names in `~/Downloads`. Collisions become `file (1).pdf`. The in-progress file is `file.pdf.download`.
nonisolated enum DownloadFilenames {
    static func sanitize(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let scalars = base.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f && scalar != "/"
        }
        var name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = "Download"
        }
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let room = max(1, 200 - (ext.isEmpty ? 0 : ext.count + 1))
            let shortened = String(stem.prefix(room))
            name = ext.isEmpty ? shortened : "\(shortened).\(ext)"
        }
        return name
    }

    static func partialName(forFinal name: String) -> String {
        name + ".download"
    }

    static func conflicts(_ name: String, taken: Set<String>) -> Bool {
        taken.contains(name) || taken.contains(partialName(forFinal: name))
    }

    /// The first free final name. `taken` includes names already in the folder and in-flight downloads.
    static func uniqueFinalName(preferred: String, taken: Set<String>) -> String {
        let cleaned = sanitize(preferred)
        if !conflicts(cleaned, taken: taken) { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        var index = 1
        while index < 10_000 {
            let candidate = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            if !conflicts(candidate, taken: taken) { return candidate }
            index += 1
        }
        let extra = String(UUID().uuidString.prefix(8))
        return ext.isEmpty ? "\(stem) (\(extra))" : "\(stem) (\(extra)).\(ext)"
    }
}

/// Which navigations become downloads. Subframes are left alone so images and scripts are not saved.
nonisolated enum DownloadPolicy {
    static func isAttachment(_ disposition: String?) -> Bool {
        guard let disposition, !disposition.isEmpty else { return false }
        let type = disposition.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return type.caseInsensitiveCompare("attachment") == .orderedSame
    }

    static func responseShouldDownload(disposition: String?, canShowMIMEType: Bool, isMainFrame: Bool) -> Bool {
        guard isMainFrame else { return false }
        if isAttachment(disposition) { return true }
        return !canShowMIMEType
    }
}

/// PDF, image, text, video, and audio open in a tab. Everything else goes to the default app.
nonisolated enum DownloadKind {
    static func opensInBrowser(filename: String, mimeType: String?) -> Bool {
        if let mime = mimeType?.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) {
            if mime == "application/pdf" { return true }
            if mime.hasPrefix("image/") || mime.hasPrefix("text/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") {
                return true
            }
            if mime == "application/json" || mime == "application/xml" || mime == "application/javascript" {
                return true
            }
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        return browserExtensions.contains(ext)
    }

    private static let browserExtensions: Set<String> = [
        "pdf",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg", "avif", "ico",
        "txt", "text", "md", "markdown", "csv", "json", "xml", "html", "htm", "css", "js", "log",
        "mp4", "m4v", "mov", "webm",
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "ogg",
    ]
}

nonisolated enum DownloadFormat {
    static func bytes(_ value: Int64) -> String {
        let sign = value < 0 ? "-" : ""
        var amount = Double(abs(value))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        let body: String
        if index == 0 {
            body = "\(abs(value)) \(units[0])"
        } else if amount >= 10 {
            body = String(format: "%.0f %@", amount, units[index])
        } else {
            body = String(format: "%.1f %@", amount, units[index])
        }
        return sign + body
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(max(0, bytesPerSecond.rounded()))) + "/s"
    }
}

/// Toolbar popover membership. Active downloads stay. Finished ones leave after a few minutes, or when cleared.
nonisolated enum DownloadList {
    static let recentInterval: TimeInterval = 5 * 60

    static func popover(
        records: [DownloadRecord],
        profileID: UUID,
        now: Date,
        recentInterval: TimeInterval = DownloadList.recentInterval
    ) -> [DownloadRecord] {
        records.filter { record in
            guard record.profileID == profileID else { return false }
            switch record.state {
            case .downloading, .paused:
                return true
            case .finished, .failed, .cancelled:
                guard !record.dismissed else { return false }
                return now.timeIntervalSince(record.updatedAt) <= recentInterval
            }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func showsToolbarButton(
        records: [DownloadRecord],
        profileID: UUID,
        now: Date,
        popoverPresented: Bool,
        pagePresented: Bool
    ) -> Bool {
        if popoverPresented || pagePresented { return true }
        return !popover(records: records, profileID: profileID, now: now).isEmpty
    }

    /// Nil when nothing is downloading, or when at least one active download has an unknown size.
    static func ringFraction(records: [DownloadRecord], profileID: UUID) -> Double? {
        let active = records.filter { $0.profileID == profileID && $0.state == .downloading }
        guard !active.isEmpty else { return nil }
        guard active.allSatisfy({ ($0.totalBytes ?? 0) > 0 }) else { return nil }
        let total = active.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        guard total > 0 else { return 0 }
        let got = active.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes ?? $1.receivedBytes) }
        return Double(got) / Double(total)
    }

    static func isDownloading(records: [DownloadRecord], profileID: UUID) -> Bool {
        records.contains { $0.profileID == profileID && $0.state == .downloading }
    }

    /// A launch cannot keep a `WKDownload`. Interrupted rows become paused when resume data survived, otherwise failed.
    static func recovered(_ records: [DownloadRecord], now: Date = .now) -> [DownloadRecord] {
        records.map { record in
            guard record.state == .downloading else { return record }
            var copy = record
            if copy.resumeData != nil {
                copy.state = .paused
            } else {
                copy.state = .failed
                if copy.errorMessage == nil || copy.errorMessage?.isEmpty == true {
                    copy.errorMessage = "Interrupted"
                }
            }
            copy.updatedAt = now
            return copy
        }
    }
}

/// Safari-shaped quarantine and "where from" values. The agent name is the app, not Safari.
nonisolated enum DownloadQuarantine {
    static let agent = "myBrowser"

    static func quarantineValue(at date: Date, agent: String = DownloadQuarantine.agent, identifier: UUID) -> String {
        let timestamp = String(Int(date.timeIntervalSince1970), radix: 16)
        return "0083;\(timestamp);\(agent);\(identifier.uuidString)"
    }

    /// Download URL first, then the page it came from. Same order Finder shows for Safari.
    static func whereFroms(source: URL?, page: URL?) -> [String] {
        var urls: [String] = []
        if let source { urls.append(source.absoluteString) }
        if let page {
            let value = page.absoluteString
            if value != urls.first { urls.append(value) }
        }
        return urls
    }

    static func apply(to file: URL, source: URL?, page: URL?, date: Date = .now, identifier: UUID = UUID()) {
        let quarantine = quarantineValue(at: date, identifier: identifier)
        setBytes(Data(quarantine.utf8), name: "com.apple.quarantine", on: file)
        let froms = whereFroms(source: source, page: page)
        guard !froms.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: froms, format: .binary, options: 0) else { return }
        setBytes(data, name: "com.apple.metadata:kMDItemWhereFroms", on: file)
    }

    private static func setBytes(_ data: Data, name: String, on file: URL) {
        let path = file.path(percentEncoded: false)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            setxattr(path, name, base, buffer.count, 0, 0)
        }
    }
}
