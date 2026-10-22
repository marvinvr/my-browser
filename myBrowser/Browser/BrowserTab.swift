import AppKit
import Observation
import WebKit

/// The live counterpart of a site `SidebarItem` (`id == item.id`). Owns at most one WKWebView,
/// created lazily by `loadIfNeeded()`.
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let profileID: UUID

    private(set) var title: String
    private(set) var url: URL?
    private(set) var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// True once `loadIfNeeded` has created the web view. Tracked on its own: `webView` is not observed.
    private(set) var isLoaded = false
    @ObservationIgnored private(set) var webView: WKWebView?

    /// Called when the page wants a new tab (Cmd-click). `inBackground` is true.
    @ObservationIgnored var onOpenInNewTab: ((URL, _ inBackground: Bool) -> Void)?
    /// window.open / target=_blank. Return a web view created with the passed configuration.
    @ObservationIgnored var onCreateWebView: ((WKWebViewConfiguration, URL?) -> WKWebView?)?
    /// Called when title or URL change, so the model can mirror them into the sidebar item.
    @ObservationIgnored var onStateChange: ((BrowserTab) -> Void)?
    /// Called when back/forward availability changes, so menus can track the selected tab.
    @ObservationIgnored var onNavigationChange: ((BrowserTab) -> Void)?
    @ObservationIgnored var faviconStore: FaviconStore?

    @ObservationIgnored private let initialURL: URL?
    @ObservationIgnored private var storedInteractionState: Data?
    /// Set when `load` happens before the web view exists, so it wins over restored history.
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var downloads: [ObjectIdentifier: WKDownload] = [:]
    @ObservationIgnored private var webDelegate: TabWebDelegate?

    init(id: UUID, profileID: UUID, url: URL?, title: String, interactionState: Data?) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.initialURL = url
        self.storedInteractionState = interactionState
    }

    /// Owns a web view WebKit already created (window.open / target=_blank). Does not load `url`.
    init(id: UUID, profileID: UUID, title: String, url: URL?, adopting webView: WKWebView) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.initialURL = nil
        self.storedInteractionState = nil
        attach(webView)
    }

    /// Creates the web view (restoring `interactionState` or loading the initial URL) if needed.
    func loadIfNeeded(using profiles: ProfileManager) {
        guard webView == nil else { return }

        let webView = WKWebView(frame: .zero, configuration: profiles.configuration(for: profileID))
        attach(webView)

        if let pendingURL {
            self.pendingURL = nil
            webView.load(URLRequest(url: pendingURL))
        } else if let storedInteractionState {
            webView.interactionState = storedInteractionState
        } else if let initialURL {
            webView.load(URLRequest(url: initialURL))
        }

        useCachedFavicon()
    }

    private func attach(_ webView: WKWebView) {
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        let webDelegate = TabWebDelegate(tab: self)
        self.webDelegate = webDelegate
        webView.navigationDelegate = webDelegate
        webView.uiDelegate = webDelegate
        observe(webView)
        self.webView = webView
        isLoaded = true
    }

    /// Shows a previously cached icon immediately, before the page finishes loading.
    func useCachedFavicon() {
        guard favicon == nil, let url else { return }
        favicon = faviconStore?.cachedFavicon(for: url)
    }

    /// Destroys the web view (pinned tab "closed"). State can be captured first via `interactionState`.
    func unload() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        downloads.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webDelegate?.tab = nil
        webDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        isLoaded = false
        isLoading = false
    }

    /// `WKWebView.interactionState` as `Data`, for the session store.
    var interactionState: Data? {
        webView?.interactionState as? Data
    }

    func load(_ url: URL) {
        pendingURL = url
        storedInteractionState = nil
        if self.url != url {
            self.url = url
            onStateChange?(self)
        }
        guard let webView else { return }
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }

    // MARK: Observation

    private func observe(_ webView: WKWebView) {
        observations = [
            bind(webView, \.title) { .title($0) },
            bind(webView, \.url) { .url($0) },
            bind(webView, \.isLoading) { .loading($0) },
            bind(webView, \.estimatedProgress) { .progress($0) },
            bind(webView, \.canGoBack) { .back($0) },
            bind(webView, \.canGoForward) { .forward($0) },
        ]
    }

    /// KVO's callback is `@Sendable` and is not guaranteed to be on the main actor. Copy the value, then hop.
    private func bind<Value: Sendable>(
        _ webView: WKWebView,
        _ keyPath: KeyPath<WKWebView, Value>,
        map: @escaping @Sendable (Value) -> Observed
    ) -> NSKeyValueObservation {
        let box = TabBox(self)
        return webView.observe(keyPath, options: [.initial, .new]) { _, change in
            guard let value = change.newValue else { return }
            let observed = map(value)
            Task { @MainActor in
                box.tab?.apply(observed)
            }
        }
    }

    private func apply(_ observed: Observed) {
        switch observed {
        case .title(let value): noteTitle(value)
        case .url(let value): noteURL(value)
        case .loading(let value): noteLoading(value)
        case .progress(let value): noteProgress(value)
        case .back(let value): noteCanGoBack(value)
        case .forward(let value): noteCanGoForward(value)
        }
    }

    private func noteTitle(_ raw: String?) {
        let next = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !next.isEmpty, next != title else { return }
        title = next
        onStateChange?(self)
    }

    private func noteURL(_ newURL: URL?) {
        guard let newURL, Self.isPageURL(newURL), newURL != url else { return }
        let previousHost = url?.host()?.lowercased()
        url = newURL
        if previousHost != newURL.host()?.lowercased() {
            favicon = faviconStore?.cachedFavicon(for: newURL)
        }
        onStateChange?(self)
    }

    private func noteLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
    }

    private func noteProgress(_ progress: Double) {
        guard estimatedProgress != progress else { return }
        estimatedProgress = progress
    }

    private func noteCanGoBack(_ value: Bool) {
        guard canGoBack != value else { return }
        canGoBack = value
        onNavigationChange?(self)
    }

    private func noteCanGoForward(_ value: Bool) {
        guard canGoForward != value else { return }
        canGoForward = value
        onNavigationChange?(self)
    }

    static func isPageURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": true
        default: false
        }
    }

    func open(url: URL?, inBackground: Bool) {
        guard let url, Self.isPageURL(url) else { return }
        onOpenInNewTab?(url, inBackground)
    }

    /// WebKit calls this synchronously. The returned view must be built with `configuration`.
    func createWebView(configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        onCreateWebView?(configuration, url)
    }

    func beginDownload(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = download
    }

    func endDownload(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = nil
    }

    func fetchFaviconIfNeeded() {
        guard let pageURL = webView?.url ?? url, let webView, let faviconStore else { return }
        Task { [weak self] in
            let image = await faviconStore.favicon(for: pageURL, webView: webView)
            if let image {
                self?.favicon = image
            }
        }
    }
}

/// Sendable stand-in for `weak self` inside the KVO callback.
private final class TabBox: @unchecked Sendable {
    weak var tab: BrowserTab?
    init(_ tab: BrowserTab) { self.tab = tab }
}

private enum Observed: Sendable {
    case title(String?)
    case url(URL?)
    case loading(Bool)
    case progress(Double)
    case back(Bool)
    case forward(Bool)
}
