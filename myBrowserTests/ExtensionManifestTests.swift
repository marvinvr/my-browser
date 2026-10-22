import Foundation
import Testing
@testable import myBrowser

struct ExtensionManifestTests {
    @Test func acceptsManifestV2AndV3() throws {
        let root = URL(fileURLWithPath: "/tmp")
        let v3 = try ExtensionManifest.parse([
            "manifest_version": 3,
            "name": "JSON Viewer",
            "version": "1.2.3",
            "description": "Formats JSON",
            "browser_specific_settings": ["gecko": ["id": "json@example.com"]],
            "options_ui": ["page": "options.html"],
        ], root: root)
        #expect(v3.manifestVersion == 3)
        #expect(v3.name == "JSON Viewer")
        #expect(v3.version == "1.2.3")
        #expect(v3.summary == "Formats JSON")
        #expect(v3.geckoID == "json@example.com")
        #expect(v3.hasOptionsPage)

        let v2 = try ExtensionManifest.parse([
            "manifest_version": 2,
            "name": "Old",
            "version": "0.9",
            "applications": ["gecko": ["id": "old@example.com"]],
        ], root: root)
        #expect(v2.manifestVersion == 2)
        #expect(v2.geckoID == "old@example.com")
        #expect(v2.hasOptionsPage == false)
    }

    @Test func rejectsManifestV1AndAMissingName() {
        let root = URL(fileURLWithPath: "/tmp")
        #expect(throws: ExtensionInstallError.unsupportedManifest(1)) {
            try ExtensionManifest.parse([
                "manifest_version": 1,
                "name": "Ancient",
                "version": "1",
            ], root: root)
        }
        #expect(throws: ExtensionInstallError.invalidManifest("name is missing.")) {
            try ExtensionManifest.parse([
                "manifest_version": 3,
                "version": "1.0",
            ], root: root)
        }
    }
}
