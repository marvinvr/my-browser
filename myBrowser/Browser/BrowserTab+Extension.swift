import WebKit

/// Hooks `BrowserModel` fills in so a tab can answer extension API calls without owning the model.
struct ExtensionTabBridge {
    var spaceID: UUID?
    weak var parentTab: BrowserTab?
    var window: () -> (any WKWebExtensionWindow)? = { nil }
    var isSelected: () -> Bool = { false }
    var index: () -> Int = { NSNotFound }
    var isPinned: () -> Bool = { false }
    var activate: () -> Void = {}
    var close: () -> Void = {}
    var setPinned: (Bool) -> Void = { _ in }
}

extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        extensionBridge.window()
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        extensionBridge.index()
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        extensionBridge.parentTab
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        title
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        extensionBridge.isPinned()
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        extensionBridge.setPinned(pinned)
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        isLoading ? url : nil
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !isLoading
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin {
            webView?.reloadFromOrigin()
        } else {
            webView?.reload()
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        extensionBridge.activate()
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        extensionBridge.isSelected()
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        extensionBridge.close()
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}
