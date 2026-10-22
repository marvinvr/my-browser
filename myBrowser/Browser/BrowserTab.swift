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

    /// Called when the page wants a new tab (target=_blank, window.open, Cmd-click). `inBackground` for Cmd-click.
    @ObservationIgnored var onOpenInNewTab: ((URL, _ inBackground: Bool) -> Void)?
    /// Called when title or URL change, so the model can mirror them into the sidebar item.
    @ObservationIgnored var onStateChange: ((BrowserTab) -> Void)?
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

    /// Creates the web view (restoring `interactionState` or loading the initial URL) if needed.
    func loadIfNeeded(using profiles: ProfileManager) {
        guard webView == nil else { return }

        let webView = WKWebView(frame: .zero, configuration: profiles.configuration(for: profileID))
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
            bind(webView, \.title) { tab, view in tab.noteTitle(view.title) },
            bind(webView, \.url) { tab, view in tab.noteURL(view.url) },
            bind(webView, \.isLoading) { tab, view in tab.noteLoading(view.isLoading) },
            bind(webView, \.estimatedProgress) { tab, view in tab.noteProgress(view.estimatedProgress) },
            bind(webView, \.canGoBack) { tab, view in tab.noteCanGoBack(view.canGoBack) },
            bind(webView, \.canGoForward) { tab, view in tab.noteCanGoForward(view.canGoForward) },
        ]
    }

    /// KVO callbacks are `@Sendable`. WebKit delivers them on the main thread; hop back onto the actor there.
    private func bind<Value>(
        _ webView: WKWebView,
        _ keyPath: KeyPath<WKWebView, Value>,
        apply: @escaping @MainActor (BrowserTab, WKWebView) -> Void
    ) -> NSKeyValueObservation {
        webView.observe(keyPath, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self, view)
            }
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
    }

    private func noteCanGoForward(_ value: Bool) {
        guard canGoForward != value else { return }
        canGoForward = value
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
