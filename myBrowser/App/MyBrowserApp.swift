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
        .commands { AppCommands(model: appDelegate.model) }
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
        #if DEBUG
        applyDebugAppearance()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        applyDebugAppearance()
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_COMMAND_BAR"] == "1" {
            model.showCommandBar(.newTab)
        }
        DebugSnapshot.install(model: model)
        #endif
    }

    #if DEBUG
    /// Snapshot-only. `defaults` and System Events cannot change this machine's appearance.
    private func applyDebugAppearance() {
        switch ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_APPEARANCE"]?.lowercased() {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            break
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        model.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
