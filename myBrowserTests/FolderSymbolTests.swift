import AppKit
import Testing

@MainActor
struct FolderSymbolTests {
    /// The open-folder outline is a catalog symbol, not an SF Symbol.
    /// `NSImage(named:)` is the lookup that reads it from the app bundle.
    @Test func openFolderSymbolLoadsFromMainBundle() {
        #expect(Bundle.main.bundleIdentifier == "ch.marvinvr.mybrowser")
        #expect(NSImage(named: "folder.open") != nil)
    }
}
