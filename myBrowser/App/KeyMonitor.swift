import AppKit

/// One local key monitor for shortcuts SwiftUI menus don't deliver reliably.
/// Control-Tab switches tabs. Escape closes the command bar, or stops the load when it is hidden.
final class KeyMonitor {
    static let shared = KeyMonitor()

    private var model: BrowserModel?
    private var monitor: Any?

    private init() {}

    func install(model: BrowserModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            let consume = MainActor.assumeIsolated {
                KeyMonitor.shared.handle(keyCode: keyCode, rawFlags: rawFlags)
            }
            return consume ? nil : event
        }
    }

    /// Returns true when the event was handled and should not be delivered.
    private func handle(keyCode: UInt16, rawFlags: UInt) -> Bool {
        guard let model else { return false }
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags).intersection([.command, .control, .option, .shift])

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

    private static let tabKey: UInt16 = 48
    private static let escapeKey: UInt16 = 53
}
