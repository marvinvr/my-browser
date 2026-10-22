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
        let directory = Self.storageDirectory()
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
        if env["MYBROWSER_DEBUG_LIBRARY"] != nil {
            seedSnapshotChrome()
        }
    }

    /// Favorites, an expanded folder, and one tab so toolbar snapshots have chrome to look at.
    /// Only runs against `MYBROWSER_DEBUG_LIBRARY`, never the real library.
    private func seedSnapshotChrome() {
        let space = model.selectedSpaceID
        if model.library.children(of: nil, section: .favorites, in: space).isEmpty {
            for (title, raw) in [("GitHub", "https://github.com"), ("YouTube", "https://www.youtube.com"), ("Apple", "https://www.apple.com")] {
                _ = model.library.addItem(spaceID: space, section: .favorites, title: title, url: URL(string: raw))
            }
        }
        if !model.library.children(of: nil, section: .pinned, in: space).contains(where: { $0.kind == .folder }),
           let folder = model.createFolder(named: "Projects", parentID: nil) {
            _ = model.library.addItem(
                spaceID: space,
                section: .pinned,
                parentID: folder.id,
                title: "Stripe",
                url: URL(string: "https://stripe.com")
            )
        }
        if model.library.children(of: nil, section: .tabs, in: space).isEmpty {
            let tab = model.library.addItem(
                spaceID: space,
                section: .tabs,
                title: "GitHub",
                url: URL(string: "https://github.com")
            )
            model.select(tab.id)
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

    /// `MYBROWSER_DEBUG_LIBRARY` points snapshot runs at a throwaway directory.
    private static func storageDirectory() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return LibraryStore.defaultDirectory()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
