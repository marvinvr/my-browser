import AppKit
import SwiftUI

@main
struct MyBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("myBrowser", id: "main") {
            MainWindowView()
                .environment(appDelegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
    }
}

/// Owns the single library, session and window model for Phase 1.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library: LibraryStore
    let session: SessionStore
    let model: BrowserModel

    override init() {
        let directory = LibraryStore.defaultDirectory()
        library = LibraryStore(directory: directory)
        session = SessionStore(directory: directory)
        model = BrowserModel(library: library, session: session)
        super.init()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
