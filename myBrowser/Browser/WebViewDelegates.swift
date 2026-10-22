import AppKit
import WebKit

/// WKWebView delegate bridge. WebKit's delegate protocols require `NSObject`.
final class TabWebDelegate: NSObject, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
        super.init()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Cmd-click is cancelled in decidePolicy. This is window.open / target=_blank:
        // hand WebKit a view created with the configuration it passed, so window.opener works.
        tab?.createWebView(configuration: configuration, url: navigationAction.request.url)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload {
            return .download
        }
        // Cmd-click a link: background tab, leave the current page alone.
        // Cancel so a target=_blank click is not also delivered to `createWebViewWith`.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            tab?.open(url: navigationAction.request.url, inBackground: true)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        // A file the web view cannot render (a zip, a disk image, …) becomes a download.
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.fetchFaviconIfNeeded()
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        Self.downloadDestination(suggestedFilename: suggestedFilename, response: response)
    }

    func downloadDidFinish(_ download: WKDownload) {
        tab?.endDownload(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        tab?.endDownload(download)
    }

    private func adopt(_ download: WKDownload) {
        download.delegate = self
        tab?.beginDownload(download)
    }

    /// A file URL in `~/Downloads` that does not exist yet. WebKit requires the destination to be absent.
    private static func downloadDestination(suggestedFilename: String, response: URLResponse) -> URL? {
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let suggested = suggestedFilename.isEmpty ? (response.suggestedFilename ?? "Download") : suggestedFilename
        let cleaned = (suggested as NSString).lastPathComponent
        let baseName = cleaned.isEmpty || cleaned == "/" || cleaned == "." ? "Download" : cleaned

        var candidate = directory.appending(path: baseName)
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path), suffix < 1000 {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            candidate = directory.appending(path: name)
            suffix += 1
        }
        return candidate
    }
}
