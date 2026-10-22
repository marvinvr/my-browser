import AppKit
import SwiftUI

/// Menu bar commands and their shortcuts. ⌘W closes the tab; ⇧⌘W closes the window.
struct AppCommands: Commands {
    let model: BrowserModel

    init(model: BrowserModel) {
        self.model = model
        KeyMonitor.shared.install(model: model)
    }

    var body: some Commands {
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
            Button("Toggle Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("s")
        }

        CommandGroup(after: .sidebar) {
            Button("Reload") { model.selectedTab?.reload() }
                .keyboardShortcut("r")
            Button("Back") { model.selectedTab?.goBack() }
                .keyboardShortcut("[")
                .disabled(model.selectedTab?.canGoBack != true)
            Button("Forward") { model.selectedTab?.goForward() }
                .keyboardShortcut("]")
                .disabled(model.selectedTab?.canGoForward != true)
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
