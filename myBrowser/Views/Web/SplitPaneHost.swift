import AppKit
import SwiftUI
import WebKit

/// One pane: the tab's web view, and its own toolbar when it is part of a split.
struct SplitPaneHost: NSViewRepresentable {
    var tabID: UUID
    var model: BrowserModel
    var focused: Bool
    var split: Bool
    var title: String

    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.trafficClearance) private var trafficClearance

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitPaneContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> SplitPaneContainer {
        SplitPaneContainer()
    }

    func updateNSView(_ container: SplitPaneContainer, context: Context) {
        installWebView(in: container, context: context)
        container.apply(
            browser: model,
            extensions: extensions,
            tabID: tabID,
            split: split,
            focused: focused,
            title: title,
            isLeading: false,
            showsWindowControls: false,
            trafficClearance: trafficClearance
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func installWebView(in container: SplitPaneContainer, context: Context) {
        guard let tab = model.tabs[tabID] else {
            container.showWebView(nil)
            return
        }
        let shouldLoad = focused || tab.isLoaded
        if shouldLoad {
            tab.loadIfNeeded(using: model.profiles)
        }
        guard let webView = tab.webView else {
            container.showWebView(nil)
            return
        }
        container.showWebView(webView)
        if context.coordinator.installedID != tabID {
            context.coordinator.installedID = tabID
        }
        tab.restoreHistoryWhenWindowed()
    }

    final class Coordinator {
        var installedID: UUID?
    }
}

final class SplitPaneContainer: NSView {
    private var webView: WKWebView?
    /// Non-flipped, so WebKit can dock the inspector along the bottom of the page.
    private let pageHost = InspectorDockHost()
    private let placeholder = NSTextField(labelWithString: "")
    private let toolbarDriver = PaneToolbarDriver()
    private var toolbarHost: NSHostingView<HostedPaneToolbar>?
    private var split = false
    private var focused = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        pageHost.translatesAutoresizingMaskIntoConstraints = true
        pageHost.wantsLayer = true
        pageHost.layer?.masksToBounds = true
        addSubview(pageHost)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 13, weight: .medium)
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.maximumNumberOfLines = 2
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Frame, not constraints. A flipped container plus edge constraints left the page
    /// shifted and wide enough to cover the gap between panes.
    /// The page lives in `pageHost`. Setting the web view to this container's bounds
    /// covers a docked inspector, and this container is flipped, which puts that dock on top.
    func showWebView(_ next: WKWebView?) {
        guard webView !== next else {
            placeholder.isHidden = next != nil
            return
        }
        if let webView {
            // The inspector frontend is a sibling of this page. Leaving it behind
            // docks the next page against the previous page's inspector.
            if WebInspector.isDocked(webView) {
                WebInspector.close(webView)
            }
            webView.removeFromSuperview()
        }
        webView = next
        pageHost.webView = next
        placeholder.isHidden = next != nil
        guard let next else { return }
        next.translatesAutoresizingMaskIntoConstraints = true
        next.clipsToBounds = true
        pageHost.addSubview(next)
        next.frame = pageHost.bounds
        pageHost.needsLayout = true
    }

    override func layout() {
        super.layout()
        let bar = split ? SidebarMetrics.toolbarHeight : 0
        toolbarHost?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bar)
        toolbarHost?.isHidden = !split
        pageHost.frame = CGRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))
    }

    func apply(
        browser: BrowserModel,
        extensions: ExtensionManager?,
        tabID: UUID,
        split: Bool,
        focused: Bool,
        title: String,
        isLeading: Bool,
        showsWindowControls: Bool,
        trafficClearance: CGFloat
    ) {
        let changed = self.split != split || self.focused != focused
        self.split = split
        self.focused = focused
        placeholder.stringValue = title.isEmpty ? "Empty pane" : title
        toolbarDriver.tabID = tabID
        toolbarDriver.focused = focused
        toolbarDriver.isLeading = isLeading
        toolbarDriver.showsWindowControls = split && showsWindowControls
        toolbarDriver.trafficClearance = trafficClearance
        if split, let extensions {
            ensureToolbar(browser: browser, extensions: extensions)
        }
        toolbarHost?.isHidden = !split
        if changed {
            applyChrome(animated: window != nil)
        } else {
            applyChrome(animated: false)
        }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome(animated: false)
    }

    private func ensureToolbar(browser: BrowserModel, extensions: ExtensionManager) {
        guard toolbarHost == nil else { return }
        let host = NSHostingView(rootView: HostedPaneToolbar(
            driver: toolbarDriver,
            browser: browser,
            extensions: extensions
        ))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.sizingOptions = []
        host.safeAreaRegions = []
        addSubview(host)
        toolbarHost = host
    }

    private func applyChrome(animated: Bool) {
        let radius: CGFloat = split ? SplitMetrics.cornerRadius : 0
        layer?.cornerRadius = radius
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        _ = animated
    }
}
