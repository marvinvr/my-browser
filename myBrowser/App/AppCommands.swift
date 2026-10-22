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
            // `Commands` does not refresh when a tab's flags change. Each item is a view
            // that reads the focused scene value, which does invalidate menu items.
            ReloadCommand(model: model)
            BackCommand(model: model)
            ForwardCommand(model: model)
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
                switch item.title {
                case "Reload":
                    item.isEnabled = model.canReload
                    ownsNavigation = true
                case "Back":
                    item.isEnabled = model.canGoBack
                    ownsNavigation = true
                case "Forward":
                    item.isEnabled = model.canGoForward
                    ownsNavigation = true
                default:
                    break
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
}

@MainActor
final class NavigationMenuFixer: NSObject, NSMenuDelegate {
    static let shared = NavigationMenuFixer()
    private var prior: NSMenuDelegate?
    private weak var model: BrowserModel?

    func install(on menu: NSMenu, model: BrowserModel) {
        self.model = model
        guard menu.delegate !== self else { return }
        prior = menu.delegate
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        prior?.menuNeedsUpdate?(menu)
        reapply(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        prior?.menuWillOpen?(menu)
        reapply(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        prior?.menuDidClose?(menu)
    }

    /// `menu.update()` validates each item against its target and puts SwiftUI's stale
    /// disabled flag back. Owning the target makes that validation read the model,
    /// so shortcuts work without opening the menu.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.title {
        case "Reload": return model?.canReload == true
        case "Back": return model?.canGoBack == true
        case "Forward": return model?.canGoForward == true
        default: return true
        }
    }

    @objc func performItem(_ item: NSMenuItem) {
        switch item.title {
        case "Reload": model?.selectedTab?.reload()
        case "Back": model?.selectedTab?.goBack()
        case "Forward": model?.selectedTab?.goForward()
        default: break
        }
    }

    private func reapply(_ menu: NSMenu) {
        guard let model else { return }
        for item in menu.items {
            switch item.title {
            case "Reload": item.isEnabled = model.canReload
            case "Back": item.isEnabled = model.canGoBack
            case "Forward": item.isEnabled = model.canGoForward
            default: continue
            }
            item.target = self
            item.action = #selector(performItem(_:))
        }
    }
}

struct BrowserNavigationState: Equatable {
    var canGoBack: Bool
    var canGoForward: Bool
    var canReload: Bool
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
