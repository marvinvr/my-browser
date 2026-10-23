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

/// A `windows.create({ type: "popup" })` window. One extension page, not a sidebar tab.
final class ExtensionPopupPanel: NSObject, WKWebExtensionWindow, WKWebExtensionTab {
    var onClose: (() -> Void)?

    private let panel: NSPanel
    private let webView: WKWebView
    private let pageURL: URL

    init(url: URL, configuration: WKWebViewConfiguration, requestedFrame: CGRect) {
        let size = Self.size(for: requestedFrame)
        pageURL = url
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        WebInspector.enableDeveloperExtras(configuration.preferences)
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        super.init()
        panel.title = "Extension popup"
        panel.identifier = NSUserInterfaceItemIdentifier("extension-popup")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        webView.isInspectable = true
        let host = InspectorDockHost(frame: NSRect(origin: .zero, size: size))
        host.autoresizingMask = [.width, .height]
        host.webView = webView
        host.addSubview(webView)
        webView.frame = host.bounds
        panel.contentView = host
        panel.setFrameOrigin(Self.origin(for: requestedFrame, size: size))
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )
        webView.load(URLRequest(url: url))
        panel.makeKeyAndOrderFront(nil)
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { [self] }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { self }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .popup }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        if panel.isMiniaturized { return .minimized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect { panel.frame }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel.close()
        completionHandler(nil)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }

    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? {
        let title = webView.title ?? ""
        return title.isEmpty ? "Extension popup" : title
    }

    func url(for context: WKWebExtensionContext) -> URL? { webView.url ?? pageURL }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        panel.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        webView.load(URLRequest(url: url))
        completionHandler(nil)
    }

    /// Posted from the main run loop. A MainActor method fails its executor check if a MainActor task is suspended.
    @objc nonisolated func panelWillClose(_ notification: Notification) {
        Task { @MainActor in
            let close = self.onClose
            self.onClose = nil
            close?()
        }
    }

    private static func size(for frame: CGRect) -> NSSize {
        let width = frame.size.width.isFinite && frame.size.width > 40 ? frame.size.width : 420
        let height = frame.size.height.isFinite && frame.size.height > 40 ? frame.size.height : 560
        return NSSize(width: min(max(width, 280), 800), height: min(max(height, 200), 900))
    }

    private static func origin(for frame: CGRect, size: NSSize) -> NSPoint {
        if frame.origin.x.isFinite, frame.origin.y.isFinite {
            return frame.origin
        }
        let screen = NSApp.mainWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(visible.maxX - size.width - 24, visible.minX), visible.maxX - size.width)
        let y = visible.midY - size.height / 2
        return NSPoint(x: x, y: y)
    }
}
