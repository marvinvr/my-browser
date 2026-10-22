import AppKit
import WebKit

/// The single main window, as extensions see it.
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var model: BrowserModel?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let model else { return [] }
        let profileID = context.webExtensionController?.configuration.identifier
        var result: [any WKWebExtensionTab] = []
        for space in model.library.orderedSpaces {
            if let profileID, space.profileID != profileID { continue }
            for item in model.navigableItems(in: space.id) where item.kind == .site {
                guard let tab = model.tabs[item.id] else { continue }
                if let profileID, tab.profileID != profileID { continue }
                result.append(tab)
            }
        }
        return result
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let model, let tab = model.selectedTab else { return nil }
        let profileID = context.webExtensionController?.configuration.identifier
        if let profileID, tab.profileID != profileID { return nil }
        return tab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = NSApp.mainWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.mainWindow?.screen?.frame ?? .null
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.mainWindow?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.size.width.isFinite, frame.size.height.isFinite else {
            completionHandler(nil)
            return
        }
        NSApp.mainWindow?.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(ExtensionInstallError.webKit("Closing the window isn't available."))
    }
}
