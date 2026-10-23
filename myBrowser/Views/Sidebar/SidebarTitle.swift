import AppKit
import Foundation

enum SidebarTitle {
    /// Pinned and favorite rows keep the saved name until the live page leaves that URL.
    /// Then the row shows the current page title. Unpinned tabs keep the live title.
    static func text(for item: SidebarItem, tab: BrowserTab?) -> String {
        if item.kind == .site, item.section != .tabs {
            if isAway(item, tab: tab) {
                return PinnedPage.liveTitle(current: tab?.title ?? "", url: tab?.url, fallback: item.title)
            }
            return storedTitle(item, url: item.url)
        }
        let liveTitle = tab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tab?.isLoaded == true, !liveTitle.isEmpty {
            return liveTitle
        }
        return storedTitle(item, url: tab?.url ?? item.url)
    }

    /// Loaded pin whose current page is not the saved URL (fragment and trailing slash ignored).
    static func isAway(_ item: SidebarItem, tab: BrowserTab?) -> Bool {
        guard item.kind == .site, item.section != .tabs, tab?.isLoaded == true else { return false }
        return PinnedPage.isAway(current: tab?.url, saved: item.url)
    }

    private static func storedTitle(_ item: SidebarItem, url: URL?) -> String {
        let stored = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        if let host = host(of: url) { return host }
        return "New Tab"
    }

    static func host(of url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false), !host.isEmpty else { return nil }
        let stripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return stripped.isEmpty ? nil : stripped
    }

    static func link(for item: SidebarItem, tab: BrowserTab?) -> URL? {
        tab?.url ?? item.url
    }

    static func monogram(url: URL?, title: String) -> String? {
        if let host = host(of: url), let first = host.first {
            return String(first).uppercased()
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isLetter || first.isNumber else { return nil }
        return String(first).uppercased()
    }
}

enum SidebarClipboard {
    static func copy(_ url: URL?) {
        guard let url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}
