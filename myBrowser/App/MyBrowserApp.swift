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
        .commands { AppCommands(model: appDelegate.model, updater: appDelegate.updater) }
    }
}

/// Owns the single library, session and window model for Phase 1.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library: LibraryStore
    let session: SessionStore
    let model: BrowserModel
    let updater = Updater()

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
        updater.start()
        #if DEBUG
        applyDebugAppearance()
        applyDebugScene()
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_COMMAND_BAR"] == "1" {
            model.showCommandBar(.newTab)
        }
        DebugSnapshot.install(model: model)
        #endif
    }

    #if DEBUG
    /// Snapshot-only scene setup. Opt-in, so a normal debug launch leaves the library alone.
    private func applyDebugScene() {
        let env = ProcessInfo.processInfo.environment
        if let name = env["MYBROWSER_DEBUG_SPACE"],
           let space = model.library.orderedSpaces.first(where: { $0.name == name }) {
            model.selectSpace(space.id)
        }
        if env["MYBROWSER_DEBUG_SEED"] == "1",
           !model.library.children(of: nil, section: .pinned, in: model.selectedSpaceID).contains(where: { $0.kind == .folder }) {
            _ = model.createFolder(named: "Projects", parentID: nil)
        }
        switch env["MYBROWSER_DEBUG_SIDEBAR"] {
        case "hidden":
            model.session.isSidebarVisible = false
        case "shown":
            model.session.isSidebarVisible = true
        default:
            break
        }
    }

    /// Snapshot-only. `defaults` and System Events cannot change this machine's appearance.
    private func applyDebugAppearance() {
        let requested = ProcessInfo.processInfo.environment["MYBROWSER_APPEARANCE"]
            ?? ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_APPEARANCE"]
        switch requested?.lowercased() {
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
