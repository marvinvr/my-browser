import Foundation
import Testing
@testable import myBrowser

struct ExtensionPackageTests {
    @Test func unpackedFolderInstalls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mb-prep-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appending(path: "src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"Tint","version":"1.0.0","description":"Sample"}"#
        try manifest.write(to: src.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        let dest = root.appending(path: "Extensions", directoryHint: .isDirectory)
        let prepared = try await ExtensionPackage.prepare(source: src, into: dest, sourceKind: .folder, preferredID: nil)
        #expect(prepared.manifest.name == "Tint")
        #expect(FileManager.default.fileExists(atPath: prepared.directory.appending(path: "manifest.json").path(percentEncoded: false)))
    }

    @Test func sourceInsideTheDestinationStillInstalls() async throws {
        let extensions = FileManager.default.temporaryDirectory
            .appending(path: "mb-prep-in-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: extensions) }
        let src = extensions.appending(path: "debug-fixture-src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let manifest = #"{"manifest_version":3,"name":"Tint","version":"1.0.0","action":{"default_popup":"popup.html","default_icon":"icon.png"}}"#
        try manifest.write(to: src.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try Data("popup".utf8).write(to: src.appending(path: "popup.html"))
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: src.appending(path: "icon.png"))
        let prepared = try await ExtensionPackage.prepare(source: src, into: extensions, sourceKind: .folder, preferredID: nil)
        #expect(prepared.id.hasPrefix("local-"))
        #expect(prepared.directory.deletingLastPathComponent().standardizedFileURL == extensions.standardizedFileURL)
    }

    @Test func storePackageRejectsADifferentSignedID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mb-crx-mismatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = Data([0x2b, 0x10, 0xff, 0x01])
        var data = Data("Cr24".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(key.count).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        data.append(key)
        let crx = root.appending(path: "extension.crx", directoryHint: .notDirectory)
        try data.write(to: crx)
        let requested = String(repeating: "b", count: 32)
        let signed = CRXArchive.extensionID(publicKey: key)
        #expect(signed != requested)
        do {
            _ = try await ExtensionPackage.prepare(
                source: crx,
                into: root.appending(path: "out", directoryHint: .isDirectory),
                sourceKind: .chromeWebStore,
                preferredID: requested
            )
            Issue.record("a mismatched store package was installed")
        } catch let error as ExtensionInstallError {
            guard case .store(let detail) = error else {
                Issue.record("expected a store error, got \(error)")
                return
            }
            #expect(detail.contains(signed))
        }
    }
}
