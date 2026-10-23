import Foundation

/// Home URL of a pinned or favorite site, compared with the page the live tab is showing.
///
/// The saved URL is the home page. Navigating does not change it. Fragments and trailing
/// slashes are the same page: `https://example.com/a#x` matches `https://example.com/a/`.
nonisolated enum PinnedPage {
    struct State: Equatable, Sendable {
        var savedURL: URL?
        var savedTitle: String
        var currentURL: URL?
        var currentTitle: String
        var loaded: Bool
        /// Session back/forward blob. Close and return-home drop it so the next open is the home URL.
        var hasInteractionState: Bool
    }

    /// Tabs store whatever page is open. Pins and favorites keep the home URL.
    static func recordsLiveURL(in section: SidebarItem.Section) -> Bool {
        section == .tabs
    }

    /// True when a loaded pin is showing a different page than the one it saves.
    static func isAway(current: URL?, saved: URL?) -> Bool {
        guard let current, isPage(current) else { return false }
        guard let saved else { return true }
        return canonical(current) != canonical(saved)
    }

    /// Scheme, host, port, path, and query. Fragment removed. Trailing slashes removed.
    /// An empty path and `/` are the same page. Host and scheme compare case-insensitively.
    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        if let scheme = components.scheme?.lowercased() {
            components.scheme = scheme
        }
        if let host = components.host?.lowercased() {
            components.host = host
        }
        var path = components.percentEncodedPath
        if path.isEmpty {
            path = "/"
        }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        return components.string ?? url.absoluteString
    }

    /// Title stored when the user replaces the home URL with the page that is open.
    static func replacementTitle(saved: String, current: String, url: URL) -> String {
        liveTitle(current: current, url: url, fallback: saved)
    }

    /// Title shown beside the away marker: the live page title, else its host, else the saved name.
    static func liveTitle(current: String, url: URL?, fallback: String) -> String {
        let live = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        if let url, let host = hostLabel(of: url) { return host }
        let stored = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return "New Tab"
    }

    /// Navigation updates the live page only. The saved URL and title stay.
    static func navigate(_ state: State, to url: URL, title: String) -> State {
        guard state.loaded else { return state }
        var next = state
        next.currentURL = url
        let live = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            next.currentTitle = live
        }
        return next
    }

    /// Unload. The home URL stays. The interaction state is dropped so the next open is that URL.
    static func close(_ state: State) -> State {
        var next = state
        next.loaded = false
        next.currentURL = nil
        next.currentTitle = ""
        next.hasInteractionState = false
        return next
    }

    /// Next open shows the saved page, not the page that was open when the tab was closed.
    static func open(_ state: State) -> State {
        var next = state
        next.loaded = true
        next.currentURL = state.savedURL
        next.currentTitle = state.savedTitle
        next.hasInteractionState = false
        return next
    }

    /// Writes the live page into the saved URL and title. No-op when the tab is already home.
    static func replaceWithCurrent(_ state: State) -> State {
        guard state.loaded, let current = state.currentURL, isAway(current: current, saved: state.savedURL) else {
            return state
        }
        var next = state
        next.savedURL = current
        next.savedTitle = replacementTitle(saved: state.savedTitle, current: state.currentTitle, url: current)
        return next
    }

    /// Loads the saved URL. Does not walk history. No-op when the tab is already home or has no URL.
    static func returnHome(_ state: State) -> State {
        guard state.loaded, let saved = state.savedURL, isAway(current: state.currentURL, saved: saved) else {
            return state
        }
        var next = state
        next.currentURL = saved
        next.currentTitle = state.savedTitle
        next.hasInteractionState = false
        return next
    }

    private static func isPage(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": true
        default: false
        }
    }

    private static func hostLabel(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        let stripped = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return stripped.isEmpty ? nil : stripped
    }
}
