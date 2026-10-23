import AppKit
import SwiftUI

@main
struct MyBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("myBrowser", id: "main") {
            MainWindowView()
                .environment(appDelegate.model)
                .environment(appDelegate.extensions)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: appDelegate.model, updater: appDelegate.updater) }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.extensions)
        }
    }
}

/// Owns the single library, session and window model for Phase 1.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library: LibraryStore
    let session: SessionStore
    let model: BrowserModel
    let sync: SyncController
    let extensions: ExtensionManager
    let updater = Updater()

    override init() {
        let directory = Self.storageDirectory()
        Onboarding.prepareForLaunch(libraryDirectory: directory)
        library = LibraryStore(directory: directory)
        session = SessionStore(directory: directory)
        extensions = ExtensionManager(directory: directory.appending(path: "Extensions", directoryHint: .isDirectory))
        extensions.connectOwner()
        model = BrowserModel(library: library, session: session, extensions: extensions)
        extensions.attach(model)
        sync = SyncController(library: library)
        super.init()
        #if DEBUG
        applyDebugAppearance()
        applyDebugAddressBar()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconApplier.apply()
        updater.start()
        model.startArchiveMonitoring()
        #if DEBUG
        applyDebugAppearance()
        applyDebugAddressBar()
        applyDebugScene()
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_COMMAND_BAR"] == "1" {
            model.showCommandBar(.newTab)
        }
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_SETTINGS"] == "1" {
            openSettingsForDebug()
        }
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_ARCHIVE"] == "1" {
            seedDebugArchive()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.model.isPresentingArchive = true
            }
        }
        if let raw = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_WINDOW_X"], let x = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for window in NSApp.windows where window.canBecomeKey {
                    var frame = window.frame
                    frame.origin.x = x
                    window.setFrame(frame, display: true)
                }
            }
        }
        installDebugExtensionsIfRequested()
        DebugSnapshot.install(model: model)
        installDebugToggle()
        #endif
    }

    #if DEBUG
    /// Snapshot-only. `MYBROWSER_DEBUG_EXTENSIONS=1` installs the Tint fixture.
    /// `MYBROWSER_DEBUG_EXTENSION_PROMPT=1` shows a sample permission sheet.
    /// `MYBROWSER_DEBUG_EXTENSION_POPUP=1` opens that fixture's popup after it loads.
    private func installDebugExtensionsIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let wantsFixture = env["MYBROWSER_DEBUG_EXTENSIONS"] == "1"
        let wantsPrompt = env["MYBROWSER_DEBUG_EXTENSION_PROMPT"] == "1"
        let wantsPopup = env["MYBROWSER_DEBUG_EXTENSION_POPUP"] == "1"
        let storeID = env["MYBROWSER_DEBUG_EXTENSION_STORE"]
        let filePath = env["MYBROWSER_DEBUG_EXTENSION_FILE"]
        guard wantsFixture || wantsPrompt || storeID != nil || filePath != nil else { return }
        if wantsFixture || wantsPopup || storeID != nil || filePath != nil {
            Task { @MainActor in
                if wantsFixture {
                    await extensions.installDebugFixture(autoGrant: true)
                }
                if let storeID, !storeID.isEmpty {
                    await extensions.installFromChromeWebStore(storeID)
                }
                if let filePath, !filePath.isEmpty {
                    await extensions.install(from: URL(fileURLWithPath: filePath))
                }
                if wantsPopup {
                    try? await Task.sleep(for: .milliseconds(500))
                    extensions.performDebugPopup()
                }
            }
        }
        if wantsPrompt {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                NSApp.activate(ignoringOtherApps: true)
                await extensions.showDebugPermissionPrompt()
            }
        }
    }

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
        if env["MYBROWSER_DEBUG_LIBRARY"] != nil, env["MYBROWSER_DEBUG_IMPORT_FILE"] == nil {
            seedSnapshotChrome()
        }
        importDebugFixture()
    }

    /// Snapshot-only. Reads a fixture path from the environment and applies it to the debug library.
    private func importDebugFixture() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MYBROWSER_DEBUG_IMPORT_FILE"], !path.isEmpty else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let kind = env["MYBROWSER_DEBUG_IMPORT_KIND"] ?? "arc"
        let plan: ImportPlan?
        if kind == "chrome" || kind == "chromium" {
            plan = ChromiumBookmarkParser.plan(
                data: data,
                options: ChromiumBookmarkParser.Options(
                    spaceName: "Chrome",
                    bookmarkBarAsFolder: env["MYBROWSER_DEBUG_IMPORT_BAR_FOLDER"] != "0"
                )
            )
        } else {
            plan = ArcSidebarParser.read(
                data: data,
                includeUnpinned: env["MYBROWSER_DEBUG_IMPORT_UNPINNED"] == "1"
            )?.plan
        }
        guard let plan else { return }
        let result = model.library.apply(plan)
        if let id = result.spaceIDs.first {
            model.selectSpace(id)
        }
        let spaceID = model.selectedSpaceID
        if let tab = model.library.children(of: nil, section: .tabs, in: spaceID).first {
            model.select(tab.id)
        }
        guard model.library.orderedSpaces.count > 1 else { return }
        for space in model.library.orderedSpaces where space.name == "Personal" && space.id != model.selectedSpaceID {
            let empty = SidebarItem.Section.allCases.allSatisfy { section in
                model.library.children(of: nil, section: section, in: space.id).isEmpty
            }
            if empty {
                model.deleteSpace(space.id)
            }
        }
    }

    /// Sample archived tabs for a snapshot. Only when the library is a throwaway directory.
    private func seedDebugArchive() {
        guard ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"] != nil else { return }
        guard model.session.archivedTabs.isEmpty else { return }
        let spaceID = model.selectedSpaceID
        let now = Date.now
        let samples: [(String, String, TimeInterval)] = [
            ("The Verge", "https://www.theverge.com", -18 * 86_400),
            ("Wikipedia", "https://en.wikipedia.org/wiki/MacOS", -6 * 86_400),
            ("Swift Forums", "https://forums.swift.org", -2 * 86_400),
        ]
        for (title, raw, age) in samples {
            guard let url = URL(string: raw) else { continue }
            let item = SidebarItem(
                spaceID: spaceID,
                section: .tabs,
                kind: .site,
                title: title,
                url: url,
                sortKey: "a0",
                createdAt: now.addingTimeInterval(age)
            )
            model.session.archivedTabs.append(SessionStore.ArchivedTab(
                item: item,
                interactionState: nil,
                archivedAt: now.addingTimeInterval(age),
                lastActiveAt: now.addingTimeInterval(age - 3_600)
            ))
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

    private func installDebugToggle() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(debugToggleSidebar(_:)),
            name: Notification.Name("ch.marvinvr.mybrowser.debug.toggleSidebar"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(debugOpenSettings(_:)),
            name: Notification.Name("ch.marvinvr.mybrowser.debug.settings"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func debugToggleSidebar(_ notification: Notification) {
        model.toggleSidebar()
    }

    @objc private func debugOpenSettings(_ notification: Notification) {
        openSettingsForDebug()
    }

    /// SwiftUI registers `showSettingsWindow:` after launch, so a delay is required.
    private func openSettingsForDebug() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.activate(ignoringOtherApps: true)
            if let item = Self.menuItem(titled: "Settings") ?? Self.menuItem(titled: "Preferences") {
                NSApp.sendAction(item.action ?? Selector(("showSettingsWindow:")), to: item.target, from: item)
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            let wanted = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_SETTINGS_TAB"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let wanted, !wanted.isEmpty else { return }
                for window in NSApp.windows {
                    guard let toolbar = window.toolbar else { continue }
                    guard let item = toolbar.items.first(where: {
                        $0.label.caseInsensitiveCompare(wanted) == .orderedSame
                    }) else { continue }
                    if let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                    }
                }
            }
        }
    }

    private static func menuItem(titled needle: String) -> NSMenuItem? {
        func walk(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title.localizedCaseInsensitiveContains(needle) { return item }
                if let found = walk(item.submenu) { return found }
            }
            return nil
        }
        return walk(NSApp.mainMenu)
    }

    /// `MYBROWSER_DEBUG_ADDRESS_BAR=top|sidebar` forces the setting for this launch.
    /// The previous UserDefaults value is put back on quit.
    private static var savedAddressBar: (key: String, previous: Any?)?

    private func applyDebugAddressBar() {
        let key = AddressBarPosition.defaultsKey
        guard let raw = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_ADDRESS_BAR"]?.lowercased(),
              AddressBarPosition(rawValue: raw) != nil else { return }
        if Self.savedAddressBar == nil {
            Self.savedAddressBar = (key, UserDefaults.standard.object(forKey: key))
        }
        UserDefaults.standard.set(raw, forKey: key)
    }

    private func restoreDebugAddressBar() {
        guard let saved = Self.savedAddressBar else { return }
        if let previous = saved.previous {
            UserDefaults.standard.set(previous, forKey: saved.key)
        } else {
            UserDefaults.standard.removeObject(forKey: saved.key)
        }
        Self.savedAddressBar = nil
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
        #if DEBUG
        restoreDebugAddressBar()
        #endif
        extensions.save()
        model.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
