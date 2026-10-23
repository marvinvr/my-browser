import AppKit
import SwiftUI
import WebKit

/// Hosts the selected site, or every pane of the selected split.
/// Web views are created once and moved between panes. A resize does not rebuild them.
struct WebContentView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        let content = model.displayedContent
        return ZStack {
            PictureInPicturePark(tabID: model.pictureInPictureTabID, model: model)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if let content {
                SplitCanvas(content: content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: content == nil)
        .background {
            NavigationSwipeMonitor()
                .allowsHitTesting(false)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Press ⌘T to open a tab")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Keeps a Picture in Picture web view inside the window when its pane is not on screen.
/// Detaching that view closes the system panel. The host is a point, so it does not show through split gaps.
private struct PictureInPicturePark: NSViewRepresentable {
    var tabID: UUID?
    var model: BrowserModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let tabID, let webView = model.tabs[tabID]?.webView else { return }
        guard webView.window == nil else { return }
        PictureInPictureParking.park(webView, window: container.window)
    }
}

enum PictureInPictureParking {
    private static let identifier = NSUserInterfaceItemIdentifier("myBrowser.pipPark")

    /// Moves `webView` into a 1×1 host on `window` without dropping it from the hierarchy for a turn.
    @MainActor
    static func park(_ webView: WKWebView, window: NSWindow?) {
        guard let content = (window ?? webView.window)?.contentView else { return }
        let host = host(in: content)
        guard webView.superview !== host else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = host.bounds
        host.addSubview(webView)
    }

    @MainActor
    private static func host(in content: NSView) -> NSView {
        if let existing = content.subviews.first(where: { $0.identifier == identifier }) {
            return existing
        }
        let host = NSView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        host.identifier = identifier
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        if let front = content.subviews.first {
            content.addSubview(host, positioned: .below, relativeTo: front)
        } else {
            content.addSubview(host)
        }
        return host
    }
}
