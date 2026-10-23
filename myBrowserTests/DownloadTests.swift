import Foundation
import Testing
@testable import myBrowser

@MainActor
struct DownloadTests {
    @Test func uniqueNamesUseParentheses() {
        #expect(DownloadFilenames.uniqueFinalName(preferred: "file.pdf", taken: []) == "file.pdf")
        #expect(DownloadFilenames.uniqueFinalName(preferred: "file.pdf", taken: ["file.pdf"]) == "file (1).pdf")
        #expect(DownloadFilenames.uniqueFinalName(preferred: "file.pdf", taken: ["file.pdf", "file (1).pdf"]) == "file (2).pdf")
        #expect(DownloadFilenames.uniqueFinalName(preferred: "notes", taken: ["notes"]) == "notes (1)")
    }

    @Test func partialNameBlocksTheSameFinalName() {
        let taken: Set<String> = ["report.pdf.download"]
        #expect(DownloadFilenames.uniqueFinalName(preferred: "report.pdf", taken: taken) == "report (1).pdf")
        #expect(DownloadFilenames.partialName(forFinal: "report (1).pdf") == "report (1).pdf.download")
    }

    @Test func sanitizeDropsPathAndEmptyNames() {
        #expect(DownloadFilenames.sanitize("folder/file.pdf") == "file.pdf")
        #expect(DownloadFilenames.sanitize("  ") == "Download")
        #expect(DownloadFilenames.sanitize(".") == "Download")
        #expect(DownloadFilenames.sanitize("../../secret.pdf") == "secret.pdf")
        #expect(!DownloadFilenames.sanitize("../../secret.pdf").contains("/"))
    }

    @Test func attachmentAndUnsupportedTypesDownloadOnTheMainFrameOnly() {
        #expect(DownloadPolicy.isAttachment("attachment"))
        #expect(DownloadPolicy.isAttachment("Attachment; filename=\"a.zip\""))
        #expect(!DownloadPolicy.isAttachment("inline"))
        #expect(!DownloadPolicy.isAttachment(nil))
        #expect(DownloadPolicy.responseShouldDownload(disposition: "attachment", canShowMIMEType: true, isMainFrame: true))
        #expect(!DownloadPolicy.responseShouldDownload(disposition: "inline", canShowMIMEType: true, isMainFrame: true))
        #expect(DownloadPolicy.responseShouldDownload(disposition: nil, canShowMIMEType: false, isMainFrame: true))
        #expect(!DownloadPolicy.responseShouldDownload(disposition: nil, canShowMIMEType: false, isMainFrame: false))
        #expect(!DownloadPolicy.responseShouldDownload(disposition: "attachment", canShowMIMEType: false, isMainFrame: false))
    }

    @Test func browserOpensPDFImageTextVideoAndAudio() {
        #expect(DownloadKind.opensInBrowser(filename: "a.pdf", mimeType: "application/pdf"))
        #expect(DownloadKind.opensInBrowser(filename: "a.png", mimeType: "image/png"))
        #expect(DownloadKind.opensInBrowser(filename: "a.txt", mimeType: "text/plain"))
        #expect(DownloadKind.opensInBrowser(filename: "a.mp4", mimeType: "video/mp4"))
        #expect(DownloadKind.opensInBrowser(filename: "a.mp3", mimeType: "audio/mpeg"))
        #expect(DownloadKind.opensInBrowser(filename: "a.json", mimeType: "application/json"))
        #expect(DownloadKind.opensInBrowser(filename: "photo.HEIC", mimeType: nil))
        #expect(!DownloadKind.opensInBrowser(filename: "a.zip", mimeType: "application/zip"))
        #expect(!DownloadKind.opensInBrowser(filename: "a.dmg", mimeType: nil))
        #expect(DownloadKind.opensInBrowser(filename: "weird.bin", mimeType: "application/pdf"))
    }

    @Test func byteFormatUsesDecimalUnits() {
        #expect(DownloadFormat.bytes(0) == "0 B")
        #expect(DownloadFormat.bytes(999) == "999 B")
        #expect(DownloadFormat.bytes(1500) == "1.5 KB")
        #expect(DownloadFormat.bytes(10_000) == "10 KB")
        #expect(DownloadFormat.bytes(1_500_000) == "1.5 MB")
        #expect(DownloadFormat.speed(800_000) == "800 KB/s")
    }

    @Test func quarantineValueMatchesSafariShape() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let value = DownloadQuarantine.quarantineValue(at: date, identifier: id)
        #expect(value == "0083;6553f100;myBrowser;AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        let source = URL(string: "https://example.com/file.pdf")!
        let page = URL(string: "https://example.com/docs")!
        #expect(DownloadQuarantine.whereFroms(source: source, page: page) == [
            "https://example.com/file.pdf",
            "https://example.com/docs",
        ])
        #expect(DownloadQuarantine.whereFroms(source: source, page: source) == ["https://example.com/file.pdf"])
    }

    @Test func quarantineAttributesRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dl-xattr-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "note.txt")
        try Data("hello".utf8).write(to: file)
        let source = URL(string: "https://example.com/note.txt")!
        let page = URL(string: "https://example.com/")!
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        DownloadQuarantine.apply(to: file, source: source, page: page, date: date, identifier: id)
        let quarantine = String(decoding: try readAttribute("com.apple.quarantine", of: file), as: UTF8.self)
        #expect(quarantine == DownloadQuarantine.quarantineValue(at: date, identifier: id))
        let froms = try PropertyListSerialization.propertyList(
            from: readAttribute("com.apple.metadata:kMDItemWhereFroms", of: file),
            options: [],
            format: nil
        ) as? [String]
        #expect(froms == ["https://example.com/note.txt", "https://example.com/"])
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func popoverKeepsActiveAndRecentItemsForThisProfile() {
        let profile = UUID()
        let other = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let active = sample(profile: profile, state: .downloading, at: now.addingTimeInterval(-10))
        let recent = sample(profile: profile, state: .finished, at: now.addingTimeInterval(-30))
        let old = sample(profile: profile, state: .finished, at: now.addingTimeInterval(-400))
        let cleared = sample(profile: profile, state: .finished, at: now, dismissed: true)
        let elsewhere = sample(profile: other, state: .downloading, at: now)
        let shown = DownloadList.popover(
            records: [old, cleared, elsewhere, recent, active],
            profileID: profile,
            now: now
        )
        #expect(shown.map(\.id) == [active.id, recent.id])
        #expect(DownloadList.showsToolbarButton(records: [old], profileID: profile, now: now, popoverPresented: false, pagePresented: false) == false)
        #expect(DownloadList.showsToolbarButton(records: [recent], profileID: profile, now: now, popoverPresented: false, pagePresented: false))
        #expect(DownloadList.showsToolbarButton(records: [], profileID: profile, now: now, popoverPresented: true, pagePresented: false))
    }

    @Test func ringUsesKnownTotalsAndStaysIndeterminateOtherwise() {
        let profile = UUID()
        let known = sample(profile: profile, state: .downloading, received: 25, total: 100)
        let other = sample(profile: profile, state: .downloading, received: 25, total: 100)
        #expect(DownloadList.ringFraction(records: [known, other], profileID: profile) == 0.25)
        let unknown = sample(profile: profile, state: .downloading, received: 10, total: nil)
        #expect(DownloadList.ringFraction(records: [known, unknown], profileID: profile) == nil)
        #expect(DownloadList.isDownloading(records: [known], profileID: profile))
        #expect(!DownloadList.isDownloading(records: [sample(profile: profile, state: .paused)], profileID: profile))
    }

    @Test func relaunchPausesInterruptedDownloadsThatHaveResumeData() {
        let now = Date(timeIntervalSince1970: 50)
        let finished = sample(state: .finished)
        var interrupted = sample(state: .downloading)
        var resumable = sample(state: .downloading)
        resumable.resumeData = Data("resume".utf8)
        let restored = DownloadList.recovered([finished, interrupted, resumable], now: now)
        #expect(restored[0].state == .finished)
        #expect(restored[1].state == .failed)
        #expect(restored[1].errorMessage == "Interrupted")
        #expect(restored[2].state == .paused)
        #expect(restored[2].resumeData == Data("resume".utf8))
    }

    @Test func catalogSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dl-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let finished = sample(state: .finished, filename: "notes.txt")
        var interrupted = sample(state: .downloading, filename: "big.zip")
        interrupted.resumeData = Data([1, 2, 3])
        let catalog = DownloadCatalog(schemaVersion: 1, items: [finished, interrupted])
        try JSONFileStorage.write(catalog, to: directory.appending(path: "downloads.json"))
        let manager = DownloadManager(directory: directory)
        #expect(manager.records.count == 2)
        #expect(manager.records.contains { $0.filename == "notes.txt" && $0.state == .finished })
        let paused = try #require(manager.records.first { $0.filename == "big.zip" })
        #expect(paused.state == .paused)
        #expect(paused.resumeData == Data([1, 2, 3]))
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(
        profile: UUID = UUID(),
        state: DownloadState,
        filename: String = "file.pdf",
        at date: Date = Date(timeIntervalSince1970: 10),
        received: Int64 = 0,
        total: Int64? = nil,
        dismissed: Bool = false
    ) -> DownloadRecord {
        DownloadRecord(
            id: UUID(),
            profileID: profile,
            filename: filename,
            finalURL: nil,
            partialURL: nil,
            sourceURL: URL(string: "https://example.com/\(filename)"),
            pageURL: URL(string: "https://example.com/"),
            mimeType: nil,
            state: state,
            receivedBytes: received,
            totalBytes: total,
            createdAt: date,
            updatedAt: date,
            finishedAt: state == .finished ? date : nil,
            errorMessage: nil,
            resumeData: nil,
            dismissed: dismissed
        )
    }

    private func readAttribute(_ name: String, of url: URL) throws -> Data {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, name, nil, 0, 0, 0)
        try #require(size > 0)
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, name, buffer.baseAddress, size, 0, 0)
        }
        try #require(read == size)
        return data
    }
}
