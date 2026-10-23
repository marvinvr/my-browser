import AppKit
import SwiftUI

/// Menu bar commands and their shortcuts. ⌘W closes the tab; ⇧⌘W closes the window.
struct AppCommands: Commands {
    let model: BrowserModel
    let updater: Updater

    init(model: BrowserModel, updater: Updater) {
        self.model = model
        self.updater = updater
        KeyMonitor.shared.install(model: model)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
        }

        CommandGroup(after: .pasteboard) {
            Button("Copy Link") { model.copyCurrentLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.showCommandBar(.newTab) }
                .keyboardShortcut("t")
            Button("Open Location") { model.showCommandBar(.editCurrent) }
                .keyboardShortcut("l")
            Divider()
            Button("Import…") { model.isPresentingImport = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        // Replacing .saveItem removes the default Close Window item, which owns ⌘W.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { model.closeSelectedTab() }
                .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Reopen Closed Tab") { model.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .sidebar) {
            ToggleSidebarCommand(model: model)
        }

        CommandGroup(after: .sidebar) {
            SplitAxisCommand(model: model)
            Divider()
            Button("Downloads") { model.toggleDownloadsPage() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            // `Commands` does not refresh when a tab's flags change. Each item is a view
            // that reads the focused scene value, which does invalidate menu items.
            ReloadCommand(model: model)
            BackCommand(model: model)
            ForwardCommand(model: model)
            PictureInPictureCommand(model: model)
            Divider()
            DeveloperMenu(model: model)
        }

        CommandMenu("History") {
            Button("Archived Tabs…") { model.isPresentingArchive = true }
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { model.selectNextTab() }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Tab") { model.selectPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(1...8, id: \.self) { number in
                Button("Select Tab \(number)") { model.selectItem(atIndex: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Button("Select Last Tab") { model.selectItem(atIndex: nil) }
                .keyboardShortcut("9")
            Divider()
            Button("Pin/Unpin Tab") { model.togglePinSelected() }
                .keyboardShortcut("d")
            Divider()
            // ⌘⇧= is Zoom In on a US keyboard, so the split command is ⌃⌘S.
            Button("Open in Split View") { model.openInSplitView() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Separate Pane") { model.separateFocusedPane() }
                .keyboardShortcut("-", modifiers: [.command, .shift])
                .disabled(!model.canSeparatePane)
            Button("Swap Panes") { model.swapFocusedPanes() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(!model.canSwapPanes)
            Button("Focus Next Pane") { model.focusAdjacentPane(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
                .disabled(!model.canSeparatePane)
            Button("Focus Previous Pane") { model.focusAdjacentPane(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
                .disabled(!model.canSeparatePane)
            Divider()
            Button("Next Space") { model.selectNextSpace() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Space") { model.selectPreviousSpace() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
    }
}

/// SwiftUI builds Back/Forward/Reload once. `menu.update()` then writes that stale
/// `disabled` flag back onto the items. Re-apply after SwiftUI, including in `menuWillOpen`.
@MainActor
enum NavigationCommands {
    static func apply(_ model: BrowserModel) {
        guard let menu = NSApp.mainMenu else { return }
        func walk(_ menu: NSMenu) {
            var ownsNavigation = false
            for item in menu.items {
                if retarget(item, model: model) {
                    ownsNavigation = true
                }
                if let submenu = item.submenu {
                    walk(submenu)
                }
            }
            if ownsNavigation {
                NavigationMenuFixer.shared.install(on: menu, model: model)
            }
        }
        walk(menu)
    }

    /// Points the item at `NavigationMenuFixer` so a shortcut reads the live model.
    /// SwiftUI's `disabled` flag goes stale, and a live shortcut would still fire.
    @discardableResult
    static func retarget(_ item: NSMenuItem, model: BrowserModel) -> Bool {
        switch item.title {
        case "Reload":
            item.isEnabled = model.canReload
        case "Back":
            item.isEnabled = model.canGoBack
        case "Forward":
            item.isEnabled = model.canGoForward
        case "Enter Picture in Picture", "Exit Picture in Picture":
            item.title = model.pictureInPictureActive ? "Exit Picture in Picture" : "Enter Picture in Picture"
            item.isEnabled = model.canPictureInPicture
        case "Separate Pane":
            item.isEnabled = model.canSeparatePane
        case "Swap Panes":
            item.isEnabled = model.canSwapPanes
        case "Focus Next Pane", "Focus Previous Pane":
            item.isEnabled = model.canSeparatePane
        case "Stack Vertically", "Side by Side":
            item.title = model.splitAxisMenuTitle
            item.isEnabled = model.canToggleSplitAxis
        case "Show Web Inspector", "Show JavaScript Console", "Show Page Source", "Reload Ignoring Cache":
            item.isEnabled = model.canReload
        default:
            return false
        }
        item.target = NavigationMenuFixer.shared
        item.action = #selector(NavigationMenuFixer.performItem(_:))
        return true
    }
}

@MainActor
final class NavigationMenuFixer: NSObject, NSMenuDelegate {
    static let shared = NavigationMenuFixer()
    /// One prior delegate per menu. The View menu and the Tabs menu both install this fixer.
    private var priors: [ObjectIdentifier: NSObject] = [:]
    private weak var model: BrowserModel?

    func install(on menu: NSMenu, model: BrowserModel) {
        self.model = model
        guard menu.delegate !== self else { return }
        if let prior = menu.delegate as? NSObject {
            priors[ObjectIdentifier(menu)] = prior
        }
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        prior(of: menu)?.menuNeedsUpdate?(menu)
        reapply(menu)
        populateExtensions(in: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        prior(of: menu)?.menuWillOpen?(menu)
        reapply(menu)
        populateExtensions(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        prior(of: menu)?.menuDidClose?(menu)
    }

    /// `menu.update()` validates each item against its target and puts SwiftUI's stale
    /// disabled flag back. Owning the target makes that validation read the model,
    /// so shortcuts work without opening the menu.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.title {
        case "Reload": return model?.canReload == true
        case "Back": return model?.canGoBack == true
        case "Forward": return model?.canGoForward == true
        case "Enter Picture in Picture", "Exit Picture in Picture":
            return model?.canPictureInPicture == true
        case "Separate Pane", "Focus Next Pane", "Focus Previous Pane":
            return model?.canSeparatePane == true
        case "Swap Panes":
            return model?.canSwapPanes == true
        case "Stack Vertically", "Side by Side":
            return model?.canToggleSplitAxis == true
        case "Show Web Inspector", "Show JavaScript Console", "Show Page Source", "Reload Ignoring Cache":
            return model?.canReload == true
        default: return true
        }
    }

    @objc func inspectExtension(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        model?.inspectExtension(id: id)
    }

    /// SwiftUI builds Inspect Extension… once. The list is filled when the Developer menu opens.
    private func populateExtensions(in menu: NSMenu) {
        guard let model,
              let item = menu.items.first(where: { $0.title == "Inspect Extension…" }),
              let submenu = item.submenu else { return }
        let targets = model.extensionInspectionTargets
        let wanted = targets.isEmpty ? ["No Extensions"] : targets.map(\.name)
        let current = submenu.items.map(\.title)
        if current == wanted, targets.isEmpty || submenu.items.allSatisfy({ $0.target === self }) { return }
        submenu.removeAllItems()
        if targets.isEmpty {
            let none = NSMenuItem(title: "No Extensions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
            return
        }
        for target in targets {
            let entry = NSMenuItem(title: target.name, action: #selector(inspectExtension(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = target.id
            submenu.addItem(entry)
        }
    }

    @objc func performItem(_ item: NSMenuItem) {
        switch item.title {
        case "Reload": model?.selectedTab?.reload()
        case "Back": model?.selectedTab?.goBack()
        case "Forward": model?.selectedTab?.goForward()
        case "Enter Picture in Picture", "Exit Picture in Picture":
            model?.togglePictureInPicture()
        case "Separate Pane": model?.separateFocusedPane()
        case "Swap Panes": model?.swapFocusedPanes()
        case "Focus Next Pane": model?.focusAdjacentPane(offset: 1)
        case "Focus Previous Pane": model?.focusAdjacentPane(offset: -1)
        case "Stack Vertically", "Side by Side": model?.toggleSelectedSplitAxis()
        case "Show Web Inspector": model?.showWebInspector()
        case "Show JavaScript Console": model?.showJavaScriptConsole()
        case "Show Page Source": model?.showPageSource()
        case "Reload Ignoring Cache": model?.reloadIgnoringCache()
        default: break
        }
    }

    private func prior(of menu: NSMenu) -> NSMenuDelegate? {
        priors[ObjectIdentifier(menu)] as? NSMenuDelegate
    }

    private func reapply(_ menu: NSMenu) {
        guard let model else { return }
        for item in menu.items {
            NavigationCommands.retarget(item, model: model)
        }
    }
}

struct BrowserNavigationState: Equatable {
    var canGoBack: Bool
    var canGoForward: Bool
    var canReload: Bool
    var canPictureInPicture: Bool = false
    var isPictureInPictureActive: Bool = false
}

private struct BrowserNavigationStateKey: FocusedValueKey {
    typealias Value = BrowserNavigationState
}

private struct SidebarVisibleKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var browserNavigation: BrowserNavigationState? {
        get { self[BrowserNavigationStateKey.self] }
        set { self[BrowserNavigationStateKey.self] = newValue }
    }

    var sidebarIsVisible: Bool? {
        get { self[SidebarVisibleKey.self] }
        set { self[SidebarVisibleKey.self] = newValue }
    }
}

/// View menu. No shortcut: ⌘S is the sidebar, and ⌘⌥ arrows switch spaces.
private struct SplitAxisCommand: View {
    var model: BrowserModel

    var body: some View {
        Button(model.splitAxisMenuTitle) { model.toggleSelectedSplitAxis() }
            .disabled(!model.canToggleSplitAxis)
    }
}

/// View menu item. The title follows the focused window so it reads Hide or Show.
private struct ToggleSidebarCommand: View {
    var model: BrowserModel
    @FocusedValue(\.sidebarIsVisible) private var sidebarIsVisible

    var body: some View {
        let visible = sidebarIsVisible ?? model.session.isSidebarVisible
        Button(visible ? "Hide Sidebar" : "Show Sidebar") {
            model.toggleSidebar()
        }
        .keyboardShortcut("s")
    }
}

private struct ReloadCommand: View {
    var model: BrowserModel
    @FocusedValue(\.browserNavigation) private var navigation

    var body: some View {
        // The shortcut is also swallowed by KeyMonitor, which is the one path for ⌘R
        // (no key-repeat, and Ctrl+R is not reload). This item stays so the menu shows ⌘R
        // and a click still reloads. BrowserTab.reload drops a second call within 200ms.
        Button("Reload") { model.selectedTab?.reload() }
            .keyboardShortcut("r")
            .disabled(navigation?.canReload != true)
    }
}

private struct BackCommand: View {
    var model: BrowserModel
    @FocusedValue(\.browserNavigation) private var navigation

    var body: some View {
        Button("Back") { model.selectedTab?.goBack() }
            .keyboardShortcut("[")
            .disabled(navigation?.canGoBack != true)
    }
}

private struct ForwardCommand: View {
    var model: BrowserModel
    @FocusedValue(\.browserNavigation) private var navigation

    var body: some View {
        Button("Forward") { model.selectedTab?.goForward() }
            .keyboardShortcut("]")
            .disabled(navigation?.canGoForward != true)
    }
}

private struct DeveloperMenu: View {
    var model: BrowserModel

    var body: some View {
        Menu("Developer") {
            Button("Show Web Inspector") { model.showWebInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Show JavaScript Console") { model.showJavaScriptConsole() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Show Page Source") { model.showPageSource() }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            Button("Reload Ignoring Cache") { model.reloadIgnoringCache() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Menu("Inspect Extension…") {
                Button("No Extensions") {}
                    .disabled(true)
            }
        }
    }
}

private struct PictureInPictureCommand: View {
    var model: BrowserModel
    @FocusedValue(\.browserNavigation) private var navigation

    var body: some View {
        let active = navigation?.isPictureInPictureActive == true
        Button(active ? "Exit Picture in Picture" : "Enter Picture in Picture") {
            model.togglePictureInPicture()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(navigation?.canPictureInPicture != true)
    }
}
