import AppKit
import WebKit

/// WKWebView delegate bridge. WebKit's delegate protocols require `NSObject`.
final class TabWebDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {
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
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // Never the user-mediated interstitial. Exempt hosts are loaded as http and stay there.
        preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }
        // Cmd-click a link: background tab, leave the current page alone.
        // Cancel so a target=_blank click is not also delivered to `createWebViewWith`.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            tab?.open(url: navigationAction.request.url, inBackground: true)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.httpsFirstDidCommit()
        tab?.syncWebNotificationPermission()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.fallbackFromHTTPSFirst(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.fallbackFromHTTPSFirst(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        // Content-Disposition: attachment, and types the web view cannot show (a zip, a disk image).
        // Subframes stay as they are so images and scripts are not saved.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        if DownloadPolicy.responseShouldDownload(
            disposition: disposition,
            canShowMIMEType: navigationResponse.canShowMIMEType,
            isMainFrame: navigationResponse.isForMainFrame
        ) {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download, webView: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download, webView: webView)
    }

    /// Download Linked File, Save Image, and Download Media. WebKit creates the `WKDownload`
    /// and tells the client through this method. The selector is the navigation-delegate SPI.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        adopt(download, webView: webView)
    }

    /// The system panel's return-to-page control. The close button pauses and leaves the mode
    /// without calling this. Synchronous: the presentation-mode message must see the flag already set.
    @objc(_webViewFullscreenMayReturnToInline:)
    nonisolated func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.tab?.notePictureInPictureRestore() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { self.tab?.notePictureInPictureRestore() }
            }
        }
    }

    /// WebKit calls this on the main thread from the run loop, sometimes while a MainActor
    /// task is suspended (extension load). A MainActor method then fails its executor check.
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.tab?.fetchFaviconIfNeeded()
        }
    }

    private func adopt(_ download: WKDownload, webView: WKWebView) {
        guard let tab, let downloads = tab.downloads else { return }
        downloads.adopt(
            download,
            profileID: tab.profileID,
            pageURL: webView.url ?? tab.url,
            webView: webView
        )
    }
}
