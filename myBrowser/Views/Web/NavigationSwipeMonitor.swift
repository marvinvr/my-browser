import AppKit
import SwiftUI
import WebKit

/// Watches a horizontal trackpad swipe on the page and ticks once when it crosses WebKit's
/// navigation distance. WebKit consumes the gesture inside `trackSwipeEvent`, so the samples
/// come from the view's display link on the common run-loop modes, which keeps firing at the
/// display's rate while that loop runs.
struct NavigationSwipeMonitor: NSViewRepresentable {
    func makeNSView(context: Context) -> NavigationSwipeMonitorView {
        let view = NavigationSwipeMonitorView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ view: NavigationSwipeMonitorView, context: Context) {}
}

final class NavigationSwipeMonitorView: NSView {
    private let monitors = NavigationSwipeMonitorBox()
    private let bridge = NavigationSwipeBridge()
    private var detent = NavigationSwipeDetent()
    private var cachedWebView: WKWebView?
    private var lastMotion = 0.0
    private var sawSwipeLayer = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            cachedWebView = nil
            stop()
            monitors.clear()
            return
        }
        bridge.view = self
        let bridge = bridge
        monitors.install { event in
            let precise = event.hasPreciseScrollingDeltas
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                bridge.view?.ingest(
                    precise: precise,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    windowNumber: windowNumber,
                    location: location
                )
            }
            return event
        }
    }

    deinit {
        monitors.clear()
    }

    func ingest(precise: Bool, deltaX: CGFloat, deltaY: CGFloat, windowNumber: Int, location: CGPoint) {
        guard precise else { return }
        guard abs(deltaX) + abs(deltaY) > 0.4 else { return }
        guard let web = webView(at: location, windowNumber: windowNumber) else { return }
        let horizontal = abs(deltaX) >= abs(deltaY)
        guard horizontal || monitors.isSampling else { return }
        arm()
    }

    private func arm() {
        lastMotion = CACurrentMediaTime()
        let bridge = bridge
        monitors.startSampling(on: self) {
            MainActor.assumeIsolated {
                bridge.view?.sample()
            }
        }
    }

    private func sample() {
        guard let web = webView() else {
            stop()
            return
        }
        let reading = NavigationSwipeLayers.reading(of: web)
        if reading.hasSwipeLayer {
            sawSwipeLayer = true
            lastMotion = CACurrentMediaTime()
            let crossed = detent.update(
                progress: reading.progress,
                direction: reading.direction,
                width: web.bounds.width,
                canGoBack: web.canGoBack,
                canGoForward: web.canGoForward
            )
            if crossed, NSApp.isActive {
                Haptics.play(.navigationThreshold)
            }
        } else if sawSwipeLayer {
            sawSwipeLayer = false
            detent.reset()
        }
        if CACurrentMediaTime() - lastMotion > 0.35 {
            detent.reset()
            stop()
        }
    }

    private func stop() {
        monitors.stopSampling()
        sawSwipeLayer = false
    }

    private func webView() -> WKWebView? {
        if let cachedWebView, cachedWebView.window != nil { return cachedWebView }
        return nil
    }

    /// The page under the pointer. A split has several web views; the swipe belongs to the one being touched.
    private func webView(at location: CGPoint, windowNumber: Int) -> WKWebView? {
        guard window?.windowNumber == windowNumber, let content = window?.contentView else { return nil }
        let local = content.convert(location, from: nil)
        guard let web = Self.webView(in: content, containing: local) else { return nil }
        cachedWebView = web
        return web
    }

    private static func webView(in view: NSView, containing point: NSPoint) -> WKWebView? {
        for subview in view.subviews.reversed() {
            let local = view.convert(point, to: subview)
            guard subview.bounds.contains(local) else { continue }
            if let web = subview as? WKWebView { return web }
            if let web = webView(in: subview, containing: local) { return web }
        }
        return nil
    }
}

/// WebKit names the layer it inserts for the history swipe. No layer means no pulse.
enum NavigationSwipeLayers {
    static let rootName = "Gesture Swipe Root Layer"
    private static let gesturePrefix = "Gesture Swipe"

    static func reading(of view: NSView) -> NavigationSwipeReading {
        NavigationSwipeReading.read(sample(of: view))
    }

    static func sample(of view: NSView) -> NavigationSwipeSample {
        let width = view.bounds.width
        guard let root = view.layer else {
            return NavigationSwipeSample(swipeRootTranslation: nil, liveTranslation: nil, width: width)
        }
        var swipeRoot: CGFloat?
        var live: CGFloat?
        var visited = 0
        var queue: [(CALayer, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, visited < 80 {
            let (layer, depth) = queue[index]
            index += 1
            visited += 1
            let name = layer.name ?? ""
            if name == rootName {
                swipeRoot = layer.transform.m41
            } else if depth > 0, !name.hasPrefix(gesturePrefix), layer.bounds.width >= width * 0.5 {
                let tx = layer.transform.m41
                if abs(tx) > abs(live ?? 0) {
                    live = tx
                }
            }
            if depth < 6, swipeRoot == nil || live == nil, let children = layer.sublayers {
                for child in children.prefix(24) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return NavigationSwipeSample(swipeRootTranslation: swipeRoot, liveTranslation: live, width: width)
    }
}

/// The monitor callback is `@Sendable`. The view is only touched on the main thread.
nonisolated private final class NavigationSwipeBridge: @unchecked Sendable {
    nonisolated(unsafe) weak var view: NavigationSwipeMonitorView?
}

nonisolated private final class NavigationSwipeMonitorBox: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var token: Any?
    private var link: CADisplayLink?
    private var onFire: @Sendable () -> Void = {}

    var isSampling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return link != nil
    }

    func install(_ handler: @escaping @Sendable (NSEvent) -> NSEvent?) {
        lock.lock()
        defer { lock.unlock() }
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: handler)
    }

    /// One display link for the gesture. Common modes include event tracking, so it fires inside WebKit's swipe.
    @MainActor
    func startSampling(on view: NSView, _ block: @escaping @Sendable () -> Void) {
        lock.lock()
        onFire = block
        let existing = link != nil
        lock.unlock()
        guard !existing else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        lock.lock()
        self.link = link
        lock.unlock()
    }

    func stopSampling() {
        lock.lock()
        let installed = link
        link = nil
        onFire = {}
        lock.unlock()
        installed?.invalidate()
    }

    func clear() {
        stopSampling()
        lock.lock()
        let installed = token
        token = nil
        lock.unlock()
        if let installed {
            NSEvent.removeMonitor(installed)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        lock.lock()
        let block = onFire
        lock.unlock()
        block()
    }

    deinit { clear() }
}
