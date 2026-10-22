import AppKit

/// One local key monitor for shortcuts SwiftUI menus don't deliver reliably.
/// Control-Tab switches tabs. Escape closes the command bar, or stops the load when it is hidden.
final class KeyMonitor {
    static let shared = KeyMonitor()

    private weak var model: BrowserModel?
    private var monitor: Any?

    private init() {}

    func install(model: BrowserModel) {
        self.model = model
        guard monitor == nil else { return }
        // The monitor has to return synchronously. Consume the shortcuts here without touching
        // the model; the action hops to the main actor and must not use assumeIsolated.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            let consume = Self.shouldConsume(keyCode: keyCode, rawFlags: rawFlags)
            if consume || Self.isPlainEscape(keyCode: keyCode, rawFlags: rawFlags) {
                Task { @MainActor in
                    KeyMonitor.shared.handle(keyCode: keyCode, rawFlags: rawFlags)
                }
            }
            return consume ? nil : event
        }
    }

    /// Shortcuts that are always eaten, including while a field editor is focused.
    /// Escape is not eaten: pages and the command-bar field need it. The hop still closes the bar or stops the load.
    nonisolated private static func shouldConsume(keyCode: UInt16, rawFlags: UInt) -> Bool {
        let flags = modifiers(rawFlags)
        if keyCode == tabKey {
            return flags == .control || flags == [.control, .shift]
        }
        if keyCode == tKey, flags == [.command, .shift] { return true }
        if keyCode == wKey, flags == [.command, .shift] { return true }
        return false
    }

    nonisolated private static func isPlainEscape(keyCode: UInt16, rawFlags: UInt) -> Bool {
        keyCode == escapeKey && modifiers(rawFlags).isEmpty
    }

    nonisolated private static func modifiers(_ rawFlags: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawFlags).intersection([.command, .control, .option, .shift])
    }

    /// Returns true when the event was handled and should not be delivered.
    private func handle(keyCode: UInt16, rawFlags: UInt) -> Bool {
        guard let model else { return false }
        let flags = Self.modifiers(rawFlags)

        if keyCode == Self.tabKey {
            if flags == .control {
                model.selectNextTab()
                return true
            }
            if flags == [.control, .shift] {
                model.selectPreviousTab()
                return true
            }
        }

        // SwiftUI gives the unshifted ⌘T / ⌘W items these events as well, so the shifted ones are handled here.
        if keyCode == Self.tKey, flags == [.command, .shift] {
            model.reopenClosedTab()
            return true
        }
        if keyCode == Self.wKey, flags == [.command, .shift] {
            NSApp.keyWindow?.performClose(nil)
            return true
        }

        if keyCode == Self.escapeKey, flags.isEmpty {
            if model.commandBarMode != nil {
                model.hideCommandBar()
                return true
            }
            if model.selectedTab?.isLoading == true {
                model.selectedTab?.stopLoading()
                return true
            }
        }
        return false
    }

    nonisolated private static let tabKey: UInt16 = 48
    nonisolated private static let escapeKey: UInt16 = 53
    nonisolated private static let tKey: UInt16 = 17
    nonisolated private static let wKey: UInt16 = 13
}
