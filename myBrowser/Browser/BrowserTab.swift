import AppKit
import Observation
import WebKit

/// The live counterpart of a site `SidebarItem` (`id == item.id`). Owns at most one WKWebView,
/// created lazily by `loadIfNeeded()`.
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id: UUID
    let profileID: UUID

    private(set) var title: String
    private(set) var url: URL?
    private(set) var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Toolbar tint. `themeColor` when that colour is opaque, else `underPageBackgroundColor`,
    /// else a sample of the page background at the top. Nil when none of those is solid.
    private(set) var themeColor: NSColor?
    /// True once `loadIfNeeded` has created the web view. Tracked on its own: `webView` is not observed.
    private(set) var isLoaded = false
    /// A large enough video is playing and the site allows Picture in Picture.
    var hasPictureInPictureVideo = false
    /// WebKit reports playback, or a large video is playing. The archive sweep refreshes this.
    var isPlayingMedia = false
    var isPictureInPictureActive = false
    /// Toolbar and menus. Stays up while PiP is active so the video can be returned inline.
    var showsPictureInPictureButton: Bool { hasPictureInPictureVideo || isPictureInPictureActive }
    @ObservationIgnored private(set) var webView: WKWebView?

    /// Called when the page wants a new tab (Cmd-click). `inBackground` is true.
    @ObservationIgnored var onOpenInNewTab: ((URL, _ inBackground: Bool) -> Void)?
    /// window.open / target=_blank. Return a web view created with the passed configuration.
    @ObservationIgnored var onCreateWebView: ((WKWebViewConfiguration, URL?) -> WKWebView?)?
    /// Called when title or URL change, so the model can mirror them into the sidebar item.
    @ObservationIgnored var onStateChange: ((BrowserTab) -> Void)?
    /// Called when back/forward availability changes, so menus can track the selected tab.
    @ObservationIgnored var onNavigationChange: ((BrowserTab) -> Void)?
    /// Playing / Picture in Picture eligibility changed.
    @ObservationIgnored var onPictureInPicture: ((BrowserTab) -> Void)?
    /// View that keeps this web view inside a window while it is in Picture in Picture.
    @ObservationIgnored var pictureInPictureHost: (() -> NSView?)?
    @ObservationIgnored var faviconStore: FaviconStore?

    @ObservationIgnored private let initialURL: URL?
    @ObservationIgnored private var storedInteractionState: Data?
    @ObservationIgnored private var historyRestoreScheduled = false
    @ObservationIgnored private var historyRestoreAttempts = 0
    /// Set when `load` happens before the web view exists, so it wins over restored history.
    @ObservationIgnored private var pendingURL: URL?
    /// The next `loadIfNeeded` was an HTTPS-first navigation and may fall back to HTTP once.
    @ObservationIgnored var wantsHTTPSFirst = false
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var httpsFirstAttempt: HTTPSFirstAttempt?
    /// The first navigation waits one turn so `didOpenTab` can register content scripts, including all frames.
    @ObservationIgnored private var initialLoadPending = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var metaTheme: ThemeSample?
    @ObservationIgnored private var underPageTheme: ThemeSample?
    @ObservationIgnored private var sampledTheme: ThemeSample?
    @ObservationIgnored private var sampleGeneration = 0
    @ObservationIgnored private var sampleTask: Task<Void, Never>?
    /// Drops a second reload from the menu shortcut and KeyMonitor landing in the same instant.
    @ObservationIgnored private var lastReloadTime: TimeInterval = -.infinity
    /// Set by `BrowserModel` before the web view exists. Downloads outlive the tab.
    @ObservationIgnored weak var downloads: DownloadManager?
    @ObservationIgnored private var webDelegate: TabWebDelegate?
    @ObservationIgnored var pictureInPictureRelay: PictureInPictureRelay?
    /// Latest frame info per document. WebKit hands out a new `WKFrameInfo` on every message.
    @ObservationIgnored var pictureInPictureFrames: [String: PictureInPictureFrame] = [:]
    /// Set while we close PiP ourselves, so the system panel's return path is not also a tab switch.
    @ObservationIgnored var suppressPictureInPictureReturn = false
    /// Stays true briefly after the last "playing" report. Hiding the app pauses the element
    /// before the focus notification runs, and auto PiP still needs to catch that video.
    @ObservationIgnored var pictureInPictureEligibleUntil = Date.distantPast
    /// Filled in by `BrowserModel` so this tab can answer `WKWebExtensionTab`.
    @ObservationIgnored var extensionBridge = ExtensionTabBridge()

    init(id: UUID, profileID: UUID, url: URL?, title: String, interactionState: Data?) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.initialURL = url
        self.storedInteractionState = interactionState
        super.init()
    }

    /// Owns a web view WebKit already created (window.open / target=_blank). Does not load `url`.
    init(id: UUID, profileID: UUID, title: String, url: URL?, adopting webView: WKWebView) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.initialURL = nil
        self.storedInteractionState = nil
        super.init()
        attach(webView)
    }

    /// Creates the web view (restoring `interactionState` or loading the initial URL) if needed.
    func loadIfNeeded(using profiles: ProfileManager) {
        guard webView == nil else { return }

        let webView = WKWebView(frame: .zero, configuration: profiles.configuration(for: profileID))
        attach(webView)
        initialLoadPending = true
        // `select` calls `didOpenTab` before this task runs, so document_start scripts see the navigation.
        Task { @MainActor [weak self] in
            self?.performInitialLoad()
        }
        useCachedFavicon()
    }

    private func performInitialLoad() {
        guard initialLoadPending, let webView else { return }
        initialLoadPending = false
        if let pendingURL {
            let httpsFirst = wantsHTTPSFirst
            wantsHTTPSFirst = false
            self.pendingURL = nil
            beginNavigation(pendingURL, in: webView, httpsFirst: httpsFirst)
        } else if let state = storedInteractionState {
            wantsHTTPSFirst = false
            webView.interactionState = state
        } else if let initialURL {
            let httpsFirst = wantsHTTPSFirst
            wantsHTTPSFirst = false
            beginNavigation(initialURL, in: webView, httpsFirst: httpsFirst)
        }
    }

    /// WebKit ignores `interactionState` until the view is in a window and has a real frame.
    /// Called from the host after the web view is installed.
    func restoreHistoryWhenWindowed() {
        guard let state = storedInteractionState else { return }
        guard let webView, webView.window != nil, webView.bounds.width > 1, webView.bounds.height > 1 else {
            guard historyRestoreAttempts < 40, !historyRestoreScheduled else { return }
            historyRestoreAttempts += 1
            historyRestoreScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.historyRestoreScheduled = false
                self?.restoreHistoryWhenWindowed()
            }
            return
        }
        let list = webView.backForwardList
        guard list.backList.isEmpty, list.forwardList.isEmpty else {
            storedInteractionState = nil
            return
        }
        webView.interactionState = state
        storedInteractionState = nil
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
        installPictureInPictureScript(on: webView)
    }

    /// Shows a previously cached icon immediately, before the page finishes loading.
    func useCachedFavicon() {
        guard favicon == nil, let url else { return }
        favicon = faviconStore?.cachedFavicon(for: url)
    }

    /// Points the displayed URL and title at a page without starting a navigation.
    /// Tests and the debug snapshot use this. A real visit goes through `load`.
    func showDisplayedLocation(url: URL, title: String) {
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlChanged = self.url != url
        let titleChanged = !nextTitle.isEmpty && nextTitle != self.title
        if urlChanged { self.url = url }
        if titleChanged { self.title = nextTitle }
        if urlChanged || titleChanged { onStateChange?(self) }
    }

    /// Destroys the web view (pinned tab "closed"). State can be captured first via `interactionState`.
    func unload() {
        sampleTask?.cancel()
        sampleTask = nil
        sampleGeneration += 1
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        tearDownPictureInPicture()
        let webView = self.webView
        let keepDownloading = webView.map { downloads?.isDownloading(in: $0) == true } ?? false
        if keepDownloading, let webView {
            downloads?.parkIfNeeded(webView)
        } else {
            webView?.stopLoading()
            webView?.removeFromSuperview()
        }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webDelegate?.tab = nil
        webDelegate = nil
        self.webView = nil
        isLoaded = false
        isLoading = false
        clearTheme()
    }

    /// `WKWebView.interactionState` as `Data`, for the session store.
    var interactionState: Data? {
        webView?.interactionState as? Data
    }

    func load(_ url: URL, httpsFirst: Bool = false) {
        pendingURL = url
        storedInteractionState = nil
        wantsHTTPSFirst = httpsFirst
        initialLoadPending = false
        if self.url != url {
            self.url = url
            onStateChange?(self)
        }
        guard let webView else { return }
        pendingURL = nil
        let first = wantsHTTPSFirst
        wantsHTTPSFirst = false
        beginNavigation(url, in: webView, httpsFirst: first)
    }

    /// HTTPS responded, so this navigation no longer falls back to HTTP.
    func httpsFirstDidCommit() {
        httpsFirstAttempt = nil
    }

    /// One silent HTTP load when the HTTPS-first attempt fails. A second failure stays failed.
    func fallbackFromHTTPSFirst(_ error: Error) {
        guard let attempt = httpsFirstAttempt, attempt.generation == navigationGeneration else { return }
        let ns = error as NSError
        guard HTTPRelaxation.isRetryableHTTPSFailure(ns) else { return }
        if let failed = HTTPRelaxation.failingURL(ns),
           let failedHost = failed.host(percentEncoded: false),
           let attemptHost = attempt.url.host(percentEncoded: false),
           !HTTPRelaxation.sameSite(host: failedHost, as: attemptHost) {
            return
        }
        guard let httpURL = HTTPRelaxation.httpFallback(from: attempt.url) else {
            httpsFirstAttempt = nil
            return
        }
        httpsFirstAttempt = nil
        load(httpURL)
    }

    private func beginNavigation(_ url: URL, in webView: WKWebView, httpsFirst: Bool) {
        navigationGeneration &+= 1
        if httpsFirst, HTTPRelaxation.httpFallback(from: url) != nil {
            httpsFirstAttempt = HTTPSFirstAttempt(url: url, generation: navigationGeneration)
        } else {
            httpsFirstAttempt = nil
        }
        Self.load(url, in: webView)
    }

    /// `file` URLs need an explicit read scope or WebKit shows a blank page.
    static func load(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    /// Ignores a second call within 200ms. ⌘R is handled by `KeyMonitor`; the menu item is a fallback
    /// and both can see one keypress.
    func reload() {
        guard let webView else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReloadTime >= 0.2 else { return }
        lastReloadTime = now
        webView.reload()
    }
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
        ] + themeObservations(webView)
        metaTheme = Self.themeSample(webView.themeColor)
        underPageTheme = Self.themeSample(webView.underPageBackgroundColor)
        publishTheme()
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

    /// Sidebar rename. The next real page title still replaces this.
    func replaceTitle(_ raw: String) {
        let next = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, next != title else { return }
        title = next
    }

    private func noteURL(_ newURL: URL?) {
        guard let newURL, Self.isPageURL(newURL), newURL != url else { return }
        let previousHost = url?.host()?.lowercased()
        url = newURL
        if previousHost != newURL.host()?.lowercased() {
            favicon = faviconStore?.cachedFavicon(for: newURL)
            clearTheme()
        }
        resetPictureInPictureFrames()
        onStateChange?(self)
    }

    private func noteLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        if !loading {
            refreshThemeColor()
        }
        onStateChange?(self)
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

    private struct HTTPSFirstAttempt {
        var url: URL
        var generation: Int
    }

    static func isPageURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": true
        default: false
        }
    }

    /// Extension documents (`app.html`, a detached popup). Not a web page, and not loaded by `isPageURL`.
    static func isExtensionPageURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "webkit-extension", "chrome-extension": true
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

    /// A download that still belongs to this tab's web view. The archive sweep leaves it open.
    var hasActiveDownload: Bool {
        guard let webView else { return false }
        return downloads?.isDownloading(in: webView) == true
    }

    /// Asks WebKit whether audio or video is playing. Picture in Picture counts as playing.
    func refreshMediaPlaybackState() async {
        var playing = hasPictureInPictureVideo || isPictureInPictureActive
        if let webView {
            let state = await webView.requestMediaPlaybackState()
            if state == .playing {
                playing = true
            }
        }
        if isPlayingMedia != playing {
            isPlayingMedia = playing
        }
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

    /// Re-read WebKit's theme colour (appearance changes update `themeColor`) and sample if it is missing.
    func refreshThemeColor() {
        guard let webView else { return }
        metaTheme = Self.themeSample(webView.themeColor)
        underPageTheme = Self.themeSample(webView.underPageBackgroundColor)
        publishTheme()
        if metaTheme?.isSolid != true {
            scheduleThemeSample()
        }
    }

    // MARK: Theme colour

    private func themeObservations(_ webView: WKWebView) -> [NSKeyValueObservation] {
        let box = TabBox(self)
        let theme = webView.observe(\.themeColor, options: [.initial, .new]) { _, change in
            let sample = Self.themeSample(change.newValue ?? nil)
            Task { @MainActor in
                box.tab?.noteMetaTheme(sample)
            }
        }
        let under = webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { _, change in
            let sample = Self.themeSample(change.newValue ?? nil)
            Task { @MainActor in
                box.tab?.noteUnderPage(sample)
            }
        }
        return [theme, under]
    }

    private func noteMetaTheme(_ sample: ThemeSample?) {
        guard metaTheme != sample else { return }
        metaTheme = sample
        publishTheme()
        if sample?.isSolid != true, isLoading == false {
            scheduleThemeSample()
        }
    }

    private func noteUnderPage(_ sample: ThemeSample?) {
        guard underPageTheme != sample else { return }
        underPageTheme = sample
        publishTheme()
    }

    private func publishTheme() {
        let chosen: ThemeSample?
        if let metaTheme, metaTheme.isSolid {
            chosen = metaTheme
        } else if let underPageTheme, underPageTheme.isSolid {
            chosen = underPageTheme
        } else if let sampledTheme, sampledTheme.isSolid {
            chosen = sampledTheme
        } else {
            chosen = nil
        }
        let next = chosen?.color
        guard !Self.sameColor(themeColor, next) else { return }
        themeColor = next
    }

    private func clearTheme() {
        sampleTask?.cancel()
        sampleTask = nil
        sampleGeneration += 1
        metaTheme = nil
        underPageTheme = nil
        sampledTheme = nil
        themeColor = nil
    }

    private func scheduleThemeSample() {
        sampleTask?.cancel()
        sampleGeneration += 1
        let generation = sampleGeneration
        sampleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.sampleTopPageColor(generation: generation)
        }
    }

    private func sampleTopPageColor(generation: Int) async {
        guard let webView, generation == sampleGeneration else { return }
        let result = try? await webView.evaluateJavaScript(Self.topColorScript)
        guard generation == sampleGeneration else { return }
        sampledTheme = Self.parseSample(result)
        publishTheme()
    }

    nonisolated private static func themeSample(_ color: NSColor?) -> ThemeSample? {
        guard let color, let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return ThemeSample(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent, a: srgb.alphaComponent)
    }

    private static func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return false }
            let close = { (x: CGFloat, y: CGFloat) in abs(x - y) < 0.004 }
            return close(a.redComponent, b.redComponent)
                && close(a.greenComponent, b.greenComponent)
                && close(a.blueComponent, b.blueComponent)
                && close(a.alphaComponent, b.alphaComponent)
        default:
            return false
        }
    }

    private static func parseSample(_ value: Any?) -> ThemeSample? {
        if value is NSNull { return nil }
        let numbers: [CGFloat]
        if let list = value as? [NSNumber] {
            numbers = list.map { CGFloat(truncating: $0) }
        } else if let list = value as? [Double] {
            numbers = list.map { CGFloat($0) }
        } else if let list = value as? [Int] {
            numbers = list.map { CGFloat($0) }
        } else if let list = value as? [Any] {
            numbers = list.compactMap { item in
                if let number = item as? NSNumber { return CGFloat(truncating: number) }
                if let number = item as? Double { return CGFloat(number) }
                if let number = item as? Int { return CGFloat(number) }
                return nil
            }
            guard numbers.count == list.count else { return nil }
        } else {
            return nil
        }
        guard numbers.count >= 3 else { return nil }
        let alpha = numbers.count >= 4 ? numbers[3] : 1
        return ThemeSample(r: numbers[0] / 255, g: numbers[1] / 255, b: numbers[2] / 255, a: alpha)
    }

    private static let topColorScript = """
    (function() {
      function solid(color) {
        if (!color) return null;
        var match = String(color).match(/rgba?\\(([^)]+)\\)/);
        if (!match) return null;
        var parts = match[1].split(",").map(function(piece) { return parseFloat(piece); });
        if (parts.length < 3 || parts.some(function(n) { return !isFinite(n); })) return null;
        var alpha = parts.length > 3 ? parts[3] : 1;
        if (!(alpha >= 0.85)) return null;
        return [parts[0], parts[1], parts[2], alpha];
      }
      var width = window.innerWidth || 0;
      var x = Math.max(1, width / 2);
      var node = document.elementFromPoint(x, 6) || document.body;
      var guardCount = 0;
      while (node && guardCount < 12) {
        var found = solid(getComputedStyle(node).backgroundColor);
        if (found) return found;
        node = node.parentElement;
        guardCount += 1;
      }
      return solid(getComputedStyle(document.documentElement).backgroundColor);
    })()
    """
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

/// sRGB sample copied out of a KVO callback. `NSColor` is not `Sendable`.
nonisolated private struct ThemeSample: Equatable, Sendable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    var isSolid: Bool { a >= 0.85 }

    var color: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
