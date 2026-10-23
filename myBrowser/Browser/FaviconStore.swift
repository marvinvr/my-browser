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
    /// Views set this from the window appearance. A dark page icon is preferred while it is true.
    @ObservationIgnored var onAppearanceChange: (() -> Void)?
    var prefersDarkIcons = false {
        didSet {
            guard prefersDarkIcons != oldValue else { return }
            cacheGeneration &+= 1
            onAppearanceChange?()
        }
    }

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
    /// The appearance-specific file wins. The other variant is the fallback.
    func cachedFavicon(for url: URL) -> NSImage? {
        _ = cacheGeneration
        _ = prefersDarkIcons
        guard let key = Self.cacheKey(for: url) else { return nil }
        if let image = lookup(Self.variant(key, dark: prefersDarkIcons)) { return image }
        return lookup(Self.variant(key, dark: !prefersDarkIcons))
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
        let choice = await iconURLs(in: webView)
        let fallback = Self.faviconICO(for: pageURL)
        var light: NSImage?
        if let lightURL = choice.light {
            light = await download(lightURL)
        }
        var dark: NSImage?
        if let darkURL = choice.dark, darkURL != choice.light {
            dark = await download(darkURL)
        }
        if light == nil, dark == nil, let fallback, fallback != choice.light, fallback != choice.dark {
            light = await download(fallback)
        }
        if let light {
            store(light, for: Self.variant(key, dark: false))
        }
        if let dark {
            store(dark, for: Self.variant(key, dark: true))
        }
        if prefersDarkIcons {
            return dark ?? light
        }
        return light ?? dark
    }

    /// Light and dark `<link rel>` hrefs. A matching `prefers-color-scheme` beats `apple-touch-icon`.
    private func iconURLs(in webView: WKWebView?) async -> (light: URL?, dark: URL?) {
        guard let webView else { return (nil, nil) }
        do {
            let result = try await webView.evaluateJavaScript(Self.iconScript)
            guard let text = result as? String, let data = text.data(using: .utf8) else { return (nil, nil) }
            let links = try JSONDecoder().decode(IconLinks.self, from: data)
            return (Self.httpURL(links.light), Self.httpURL(links.dark))
        } catch {
            return (nil, nil)
        }
    }

    private struct IconLinks: Decodable {
        var light: String?
        var dark: String?
    }

    private func download(_ url: URL) async -> NSImage? {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let image = NSImage(data: data), Self.isUsable(image) else { return nil }
            return Self.normalized(image)
        } catch {
            return nil
        }
    }

    private func lookup(_ key: String) -> NSImage? {
        if let image = memory[key] { return image }
        guard let file = fileURL(for: key), let image = NSImage(contentsOf: file), Self.isUsable(image) else {
            return nil
        }
        let clean = Self.normalized(image)
        memory[key] = clean
        return clean
    }

    private func store(_ image: NSImage, for key: String) {
        memory[key] = image
        if let file = fileURL(for: key), let png = Self.pngData(from: image) {
            try? png.write(to: file, options: .atomic)
        }
        cacheGeneration &+= 1
    }

    /// `github.com.dark` is the dark file. The plain host is the light file, including icons saved before variants.
    private static func variant(_ key: String, dark: Bool) -> String {
        dark ? key + ".dark" : key
    }

    private static func httpURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
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

    /// One premultiplied bitmap. Transparent padding stays clear; nothing is flattened to black.
    private static func normalized(_ image: NSImage) -> NSImage {
        let (width, height) = FaviconBitmap.pixelSize(of: image, cap: 128)
        return FaviconBitmap.rendered(image, width: width, height: height) ?? image
    }

    private static func pngData(from image: NSImage) -> Data? {
        let (width, height) = FaviconBitmap.pixelSize(of: image, cap: 128)
        return FaviconBitmap.pngData(of: image, width: width, height: height)
    }

    /// Picks one href per appearance. An explicit `prefers-color-scheme` icon outranks `apple-touch-icon`.
    private static let iconScript = """
    (() => {
      const links = Array.from(document.querySelectorAll(
        'link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"], link[rel="shortcut icon"]'
      ));
      const schemeOf = (link) => {
        const media = (link.getAttribute("media") || "").toLowerCase();
        if (/prefers-color-scheme\\s*:\\s*light/.test(media)) return "light";
        if (/not\\s*\\([^)]*prefers-color-scheme\\s*:\\s*dark/.test(media)) return "light";
        if (/prefers-color-scheme\\s*:\\s*dark/.test(media)) return "dark";
        return "";
      };
      const pick = (dark) => {
        let best = null;
        let bestScore = -1;
        for (const link of links) {
          const rel = (link.getAttribute("rel") || "").toLowerCase();
          const scheme = schemeOf(link);
          if (dark && scheme === "light") continue;
          if (!dark && scheme === "dark") continue;
          const sizes = (link.getAttribute("sizes") || "").toLowerCase();
          let size = sizes === "any" ? 512 : 0;
          for (const part of sizes.split(/\\s+/)) {
            const match = part.match(/(\\d+)x(\\d+)/);
            if (match) size = Math.max(size, parseInt(match[1], 10));
          }
          let value = size;
          if ((dark && scheme === "dark") || (!dark && scheme === "light")) value += 30000;
          if (rel.includes("apple-touch-icon")) value += 10000;
          else if (rel.includes("icon")) value += 1000;
          if (value > bestScore && link.href) {
            bestScore = value;
            best = link.href;
          }
        }
        return best;
      };
      const light = pick(false);
      const dark = pick(true);
      if (!light && !dark) return null;
      return JSON.stringify({ light: light, dark: dark });
    })()
    """
}
