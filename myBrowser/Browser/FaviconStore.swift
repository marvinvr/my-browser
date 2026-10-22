import AppKit
import Foundation
import Observation
import WebKit

/// Memory and disk cache of site icons, keyed by host. Not synced.
/// Disk files live in `<Application Support>/myBrowser/Favicons/<host>.png`.
@Observable
final class FaviconStore {
    private let directory: URL?
    private let session: URLSession
    @ObservationIgnored private var memory: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Bumped when a newly fetched icon is stored, so sidebar views refresh.
    private(set) var cacheGeneration = 0

    /// - Parameter directory: The app support directory (`…/myBrowser`). `nil` keeps icons in memory only.
    init(directory: URL?) {
        if let directory {
            let folder = directory.appending(path: "Favicons", directoryHint: .isDirectory)
            self.directory = folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            self.directory = nil
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(ProfileManager.safariApplicationName)"
        ]
        session = URLSession(configuration: configuration)
    }

    /// Synchronous lookup for sidebar rows whose tab is not loaded. Checks memory, then disk.
    func cachedFavicon(for url: URL) -> NSImage? {
        _ = cacheGeneration
        guard let key = Self.cacheKey(for: url) else { return nil }
        if let image = memory[key] { return image }
        guard let file = fileURL(for: key), let image = NSImage(contentsOf: file), Self.isUsable(image) else {
            return nil
        }
        memory[key] = image
        return image
    }

    /// Resolves the best icon for a loaded page, then downloads and caches it.
    func favicon(for pageURL: URL, webView: WKWebView?) async -> NSImage? {
        guard let key = Self.cacheKey(for: pageURL) else { return nil }
        if let cached = cachedFavicon(for: pageURL) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task { await self.fetch(pageURL: pageURL, key: key, webView: webView) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    // MARK: Fetch

    private func fetch(pageURL: URL, key: String, webView: WKWebView?) async -> NSImage? {
        let fallback = Self.faviconICO(for: pageURL)
        let preferred = await iconURL(in: webView)
        if let preferred, preferred != fallback, let image = await download(preferred) {
            store(image, for: key)
            return image
        }
        if let fallback, let image = await download(fallback) {
            store(image, for: key)
            return image
        }
        return nil
    }

    /// Best `<link rel~=icon>` href. Prefers `apple-touch-icon`, then the largest declared size.
    private func iconURL(in webView: WKWebView?) async -> URL? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(Self.iconScript)
            guard let href = result as? String, !href.isEmpty, let url = URL(string: href) else { return nil }
            guard url.scheme == "http" || url.scheme == "https" else { return nil }
            return url
        } catch {
            return nil
        }
    }

    private func download(_ url: URL) async -> NSImage? {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let image = NSImage(data: data), Self.isUsable(image) else { return nil }
            return image
        } catch {
            return nil
        }
    }

    private func store(_ image: NSImage, for key: String) {
        memory[key] = image
        if let file = fileURL(for: key), let png = Self.pngData(from: image) {
            try? png.write(to: file, options: .atomic)
        }
        cacheGeneration &+= 1
    }

    // MARK: Keys and files

    private static func cacheKey(for url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let name = String(key.map { character in
            if character.isLetter || character.isNumber || character == "." || character == "-" {
                return character
            }
            return "_"
        })
        guard !name.isEmpty else { return nil }
        return directory.appending(path: name + ".png")
    }

    private static func faviconICO(for pageURL: URL) -> URL? {
        guard let host = pageURL.host(), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = pageURL.scheme?.lowercased() == "http" ? "http" : "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }

    private static func isUsable(_ image: NSImage) -> Bool {
        image.isValid && image.size.width > 0 && image.size.height > 0
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static let iconScript = """
    (() => {
      const links = Array.from(document.querySelectorAll(
        'link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"], link[rel="shortcut icon"]'
      ));
      const score = (link) => {
        const rel = (link.getAttribute("rel") || "").toLowerCase();
        const sizes = (link.getAttribute("sizes") || "").toLowerCase();
        let size = sizes === "any" ? 512 : 0;
        for (const part of sizes.split(/\\s+/)) {
          const match = part.match(/(\\d+)x(\\d+)/);
          if (match) size = Math.max(size, parseInt(match[1], 10));
        }
        let value = size;
        if (rel.includes("apple-touch-icon")) value += 10000;
        else if (rel.includes("icon")) value += 1000;
        return value;
      };
      links.sort((a, b) => score(b) - score(a));
      return links.length ? links[0].href : null;
    })()
    """
}
