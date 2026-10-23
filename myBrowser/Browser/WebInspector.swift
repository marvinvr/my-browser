import AppKit
import WebKit

/// Opens WebKit's Web Inspector for a page.
///
/// macOS 26 can mark a web view inspectable, and the private `developerExtrasEnabled`
/// preference adds Inspect Element to the context menu. Nothing public shows the
/// inspector window. `_inspector` / `show` / `attach` is the same private pair other
/// WKWebView browsers use. Each call checks `responds(to:)` and does nothing when
/// this WebKit does not implement it. The dock is the default; the inspector's own
/// button detaches it into a window.
enum WebInspector {
    enum Panel {
        case inspector
        case console
        case sources
    }

    /// Call before a web view owns the configuration. WebKit reads the preference at creation.
    static func enableDeveloperExtras(_ preferences: WKPreferences) {
        preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    /// Shows `panel` and docks it to `webView` when the page is on screen and large enough.
    /// A background page stays in its own window: there is nothing to dock to.
    static func open(_ panel: Panel, on webView: WKWebView) {
        webView.isInspectable = true
        guard let inspector = inspectorObject(for: webView) else { return }
        let primary = selector(for: panel)
        if inspector.responds(to: primary) {
            inspector.perform(primary)
        } else if panel != .inspector, inspector.responds(to: showSelector) {
            inspector.perform(showSelector)
        } else {
            return
        }
        guard canDock(webView) else { return }
        perform(attachSelector, on: inspector)
        // `show` can return before the frontend exists. Keep asking until the dock
        // appears. An already-attached inspector ignores the repeat.
        scheduleAttach(webView, attempts: 20)
    }

    private static func scheduleAttach(_ webView: WKWebView, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard canDock(webView), let inspector = inspectorObject(for: webView) else { return }
            if isDocked(webView) { return }
            perform(attachSelector, on: inspector)
            if !isDocked(webView) {
                scheduleAttach(webView, attempts: attempts - 1)
            }
        }
    }

    static func close(_ webView: WKWebView) {
        let host = webView.superview
        if let inspector = inspectorObject(for: webView) {
            perform(closeSelector, on: inspector)
        }
        host?.needsLayout = true
    }

    static func isDocked(_ webView: WKWebView) -> Bool {
        dockedFrontend(beside: webView) != nil
    }

    /// The inspector frontend WebKit inserted next to the page. Nil when detached or closed.
    static func dockedFrontend(beside page: WKWebView) -> WKWebView? {
        guard let parent = page.superview else { return nil }
        for view in parent.subviews {
            guard let other = view as? WKWebView, other !== page, other.window === page.window else { continue }
            return other
        }
        return nil
    }

    /// WebKit's bottom dock uses a non-flipped host: the inspector sits at y = 0.
    /// Leave a split that already fills the host. Otherwise restore it from the
    /// inspector's current edge so a later layout does not cover the dock.
    static func refitIfNeeded(page: WKWebView, inspector: WKWebView, in bounds: CGRect) {
        guard bounds.width > 40, bounds.height > 40 else { return }
        if dockFits(page: page.frame, inspector: inspector.frame, in: bounds) { return }
        guard inspector.frame.width > 40, inspector.frame.height > 40 else { return }
        let side = dockSide(page: page.frame, inspector: inspector.frame, in: bounds)
        switch side {
        case .bottom:
            let height = min(max(inspector.frame.height, 80), bounds.height * 0.8)
            inspector.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            page.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
        case .right:
            let width = min(max(inspector.frame.width, 160), bounds.width * 0.7)
            inspector.frame = CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
            page.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        case .left:
            let width = min(max(inspector.frame.width, 160), bounds.width * 0.7)
            inspector.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            page.frame = CGRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        }
    }

    private static func canDock(_ webView: WKWebView) -> Bool {
        webView.window != nil && !webView.isHidden && webView.bounds.width > 80 && webView.bounds.height > 80
    }

    private static func inspectorObject(for webView: WKWebView) -> NSObject? {
        guard webView.responds(to: inspectorSelector) else { return nil }
        return webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject
    }

    private static func perform(_ selector: Selector, on object: NSObject) {
        guard object.responds(to: selector) else { return }
        object.perform(selector)
    }

    private static func selector(for panel: Panel) -> Selector {
        switch panel {
        case .inspector: showSelector
        case .console: consoleSelector
        case .sources: sourcesSelector
        }
    }

    private enum DockSide {
        case bottom
        case left
        case right
    }

    private static func dockFits(page: CGRect, inspector: CGRect, in bounds: CGRect) -> Bool {
        let union = page.union(inspector)
        let covers = abs(union.width - bounds.width) < 2
            && abs(union.height - bounds.height) < 2
            && abs(union.minX - bounds.minX) < 2
            && abs(union.minY - bounds.minY) < 2
        let overlap = page.intersection(inspector)
        return covers && overlap.width < 2 && overlap.height < 2
    }

    private static func dockSide(page: CGRect, inspector: CGRect, in bounds: CGRect) -> DockSide {
        if inspector.minX >= page.maxX - 4 { return .right }
        if page.minX >= inspector.maxX - 4 { return .left }
        if inspector.maxY <= page.minY + 4 { return .bottom }
        if inspector.maxX > bounds.midX && inspector.width < bounds.width * 0.85 { return .right }
        if inspector.minX < 4 && inspector.maxX < bounds.midX { return .left }
        return .bottom
    }

    private static let inspectorSelector = NSSelectorFromString("_inspector")
    private static let showSelector = NSSelectorFromString("show")
    private static let consoleSelector = NSSelectorFromString("showConsole")
    private static let sourcesSelector = NSSelectorFromString("showResources")
    private static let attachSelector = NSSelectorFromString("attach")
    private static let closeSelector = NSSelectorFromString("close")
}

/// Non-flipped surface under one page. WebKit docks the inspector as a sibling and
/// measures that dock from the bottom-left. The pane that owns this host is flipped,
/// so the page cannot be the view WebKit resizes directly.
final class InspectorDockHost: NSView {
    weak var webView: WKWebView?

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        guard let webView, webView.window === window else { return }
        if let inspector = WebInspector.dockedFrontend(beside: webView) {
            WebInspector.refitIfNeeded(page: webView, inspector: inspector, in: bounds)
            return
        }
        if webView.frame != bounds {
            webView.frame = bounds
        }
    }
}
