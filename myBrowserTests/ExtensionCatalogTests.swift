import Foundation
import Testing
@testable import myBrowser

struct ExtensionCatalogTests {
    @Test func roundTripSortsAndDropsDeniedCopiesOfGrants() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mybrowser-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let later = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let tint = ExtensionRecord(
            id: "tint",
            name: "Tint",
            version: "1.0.0",
            source: .folder,
            directory: "tint",
            enabledProfileIDs: [later, earlier, later],
            grantedPermissions: ["tabs", "storage", "tabs"],
            deniedPermissions: ["tabs", "cookies"],
            grantedMatchPatterns: ["https://example.com/*"],
            deniedMatchPatterns: ["https://example.com/*", "<all_urls>"],
            hasOptionsPage: false,
            summary: "Sample"
        )
        let zebra = ExtensionRecord(
            id: "zebra",
            name: "Zebra",
            version: "0.1",
            source: .chromeWebStore,
            directory: "zebra",
            enabledProfileIDs: [],
            grantedPermissions: [],
            deniedPermissions: [],
            grantedMatchPatterns: [],
            deniedMatchPatterns: [],
            hasOptionsPage: true,
            summary: ""
        )

        try ExtensionCatalogStore.save([zebra, tint], to: directory)
        let loaded = try ExtensionCatalogStore.load(from: directory)
        #expect(loaded.map(\.name) == ["Tint", "Zebra"])

        let saved = try #require(loaded.first { $0.id == "tint" })
        #expect(saved.enabledProfileIDs == [earlier, later])
        #expect(saved.grantedPermissions == ["storage", "tabs"])
        #expect(saved.deniedPermissions == ["cookies"])
        #expect(saved.grantedMatchPatterns == ["https://example.com/*"])
        #expect(saved.deniedMatchPatterns == ["<all_urls>"])
        #expect(saved.source == .folder)

        let file = try Data(contentsOf: ExtensionCatalogStore.fileURL(in: directory))
        let json = try JSONSerialization.jsonObject(with: file) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == 1)

        let empty = FileManager.default.temporaryDirectory
            .appending(path: "mybrowser-catalog-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(try ExtensionCatalogStore.load(from: empty) == [])
    }
}
