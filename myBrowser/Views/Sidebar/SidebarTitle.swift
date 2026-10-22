import AppKit
import Foundation

enum SidebarTitle {
    /// Tab title when the tab is loaded, otherwise the item title, otherwise the host.
    static func text(for item: SidebarItem, tab: BrowserTab?) -> String {
        let liveTitle = tab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tab?.isLoaded == true, !liveTitle.isEmpty {
            return liveTitle
        }
        let stored = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        if let host = host(of: tab?.url ?? item.url) { return host }
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
