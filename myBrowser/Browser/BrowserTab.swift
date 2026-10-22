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
    @ObservationIgnored private(set) var webView: WKWebView?

    /// Called when the page wants a new tab (target=_blank, window.open, Cmd-click). `inBackground` for Cmd-click.
    @ObservationIgnored var onOpenInNewTab: ((URL, _ inBackground: Bool) -> Void)?
    /// Called when title/url change, so the model can mirror them into the sidebar item.
    @ObservationIgnored var onStateChange: ((BrowserTab) -> Void)?

    @ObservationIgnored private let initialURL: URL?
    @ObservationIgnored private let initialInteractionState: Data?

    init(id: UUID, profileID: UUID, url: URL?, title: String, interactionState: Data?) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.initialURL = url
        self.initialInteractionState = interactionState
    }

    var isLoaded: Bool { webView != nil }

    /// Creates the web view (restoring `interactionState` or loading the initial URL) if needed.
    func loadIfNeeded(using profiles: ProfileManager) {
        // TODO(worker B)
    }

    /// Destroys the web view (pinned tab "closed"). State can be captured first via `interactionState`.
    func unload() {
        webView = nil
    }

    var interactionState: Data? {
        // TODO(worker B)
        nil
    }

    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
}
