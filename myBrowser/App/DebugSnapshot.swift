#if DEBUG
import AppKit
import WebKit

/// DEBUG-only window capture. Screen recording is denied on this machine, so the app draws itself.
///
/// `ch.marvinvr.mybrowser.debug.snapshot` — userInfo["path"] is an absolute PNG path.
enum DebugSnapshot {
    private static var relays: [SnapshotRelay] = []
    private static weak var attachedModel: BrowserModel?

    static func install(model: BrowserModel) {
        attachedModel = model
        guard relays.isEmpty else { return }
        // `.capture` is the same shot as `.snapshot`. Snapshot scripts can use it when another
        // debug build is already listening for `.snapshot`.
        for name in ["ch.marvinvr.mybrowser.debug.snapshot", "ch.marvinvr.mybrowser.debug.capture"] {
            relays.append(observe(name) { note in
                let path = note.userInfo?["path"] as? String
                Task { @MainActor in
                    await DebugSnapshot.capture(to: path)
                }
            })
        }
        relays.append(observe("ch.marvinvr.mybrowser.debug.open") { note in
            let raw = note.userInfo?["url"] as? String
            Task { @MainActor in
                guard let raw, let url = URL(string: raw) else { return }
                attachedModel?.openInCurrentTab(url)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.reload") { _ in
            Task { @MainActor in
                attachedModel?.selectedTab?.reload()
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.appearance") { note in
            let mode = (note.userInfo?["mode"] as? String)?.lowercased()
            Task { @MainActor in
                switch mode {
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                default: break
                }
                attachedModel?.selectedTab?.refreshThemeColor()
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.copy") { _ in
            Task { @MainActor in
                attachedModel?.copyCurrentLink()
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.command") { note in
            let mode = note.userInfo?["mode"] as? String
            Task { @MainActor in
                guard let model = attachedModel else { return }
                switch mode {
                case "new": model.showCommandBar(.newTab)
                case "hide": model.hideCommandBar()
                default: model.showCommandBar(.editCurrent)
                }
            }
        })
    }

    /// Selector observer with `.deliverImmediately`, so `userInfo` survives when the app is not frontmost.
    private static func observe(
        _ name: String,
        body: @escaping @Sendable (Notification) -> Void
    ) -> SnapshotRelay {
        let relay = SnapshotRelay(body)
        DistributedNotificationCenter.default().addObserver(
            relay,
            selector: #selector(SnapshotRelay.onNote(_:)),
            name: Notification.Name(name),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        return relay
    }

    @MainActor
    private static func capture(to path: String?) async {
        guard let path, path.hasPrefix("/") else { return }
        guard let window = mainWindow(), let content = window.contentView, content.bounds.width > 1, content.bounds.height > 1 else {
            return
        }
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // behindWindow vibrancy draws sidebar labels as clear pixels in an offscreen cache.
        // Sample a solid material for the capture, then put the real material back.
        let effects = visualEffectViews(in: content)
        let savedEffects = effects.map { (view: $0, material: $0.material, blending: $0.blendingMode) }
        for effect in effects {
            effect.blendingMode = .withinWindow
            effect.material = .windowBackground
        }
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()

        let bounds = content.bounds
        guard let cache = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            for item in savedEffects {
                item.view.material = item.material
                item.view.blendingMode = item.blending
            }
            return
        }
        content.cacheDisplay(in: bounds, to: cache)
        for item in savedEffects {
            item.view.material = item.material
            item.view.blendingMode = item.blending
        }

        var page: (NSImage, NSRect)?
        if let webView = model?.selectedTab?.webView, webView.window != nil, webView.bounds.width > 1 {
            let configuration = WKSnapshotConfiguration()
            if let shot = try? await webView.takeSnapshot(configuration: configuration) {
                let frame = webView.convert(webView.bounds, to: content)
                page = (shot, frame)
            }
        }

        var buttons: [(NSImage, NSRect)] = []
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), button.bounds.width > 1 else { continue }
            guard let buttonRep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { continue }
            button.cacheDisplay(in: button.bounds, to: buttonRep)
            let image = NSImage(size: button.bounds.size)
            image.addRepresentation(buttonRep)
            let frame = content.convert(button.convert(button.bounds, to: nil), from: nil)
            buttons.append((image, frame))
        }

        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: cache.pixelsWide,
            pixelsHigh: cache.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        output.size = bounds.size

        let chrome = NSImage(size: bounds.size)
        chrome.addRepresentation(cache)

        var background = NSColor.windowBackgroundColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? NSColor.windowBackgroundColor
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        NSGraphicsContext.current?.imageInterpolation = .high

        // Vibrancy cacheDisplays as clear pixels, which read as black. Paint the window color behind them.
        background.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        chrome.draw(in: NSRect(origin: .zero, size: bounds.size), from: .zero, operation: .sourceOver, fraction: 1)
        for (image, frame) in sidebarCaches(in: content) {
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        if let (shot, frame) = page {
            shot.draw(in: imageRect(for: frame, in: content), from: .zero, operation: .sourceOver, fraction: 1)
        }
        if let overlay = overlayCapture(in: content) {
            // Glass often cacheDisplays as clear pixels, and the window background is white,
            // so a white card disappears on the page. A slightly gray card keeps the panel readable.
            // An opaque panel image covers it.
            let card = NSBezierPath(roundedRect: overlay.panel, xRadius: 14, yRadius: 14)
            NSColor(deviceWhite: 0.97, alpha: 1).setFill()
            card.fill()
            NSGraphicsContext.current?.saveGraphicsState()
            card.addClip()
            for (image, frame) in overlay.images {
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        for (image, frame) in buttons {
            image.draw(in: imageRect(for: frame, in: content), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = output.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Content view is flipped; the bitmap context is not. Map a content-view rect into the image.
    private static func imageRect(for frame: NSRect, in content: NSView) -> NSRect {
        guard content.isFlipped else { return frame }
        return NSRect(
            x: frame.minX,
            y: content.bounds.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Per-view caches of the sidebar column. The root cache leaves that column blank,
    /// and the toolbar buttons are too small to be caught by a column-sized walk.
    private static func sidebarCaches(in root: NSView) -> [(NSImage, NSRect)] {
        var images: [(NSImage, NSRect)] = []
        func walk(_ view: NSView) {
            let frame = view.convert(view.bounds, to: root)
            let inSidebar = frame.minX < 420 && frame.maxX < 460 && frame.width > 1
            if inSidebar, view.bounds.width >= 12, view.bounds.height >= 12, !(view is NSVisualEffectView),
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let image = NSImage(size: view.bounds.size)
                image.addRepresentation(rep)
                images.append((image, imageRect(for: frame, in: root)))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return images
    }

    private struct OverlayCapture {
        var panel: NSRect
        var images: [(NSImage, NSRect)]
    }

    /// The command bar sits over the page, so it is drawn after the web snapshot.
    /// One cache of the panel when that cache has pixels. Glass often does not, so the
    /// fallback is the first opaque descendant of each branch, clipped to the panel.
    private static func overlayCapture(in root: NSView) -> OverlayCapture? {
        guard let panel = overlayPanel(in: root) else { return nil }
        let panelFrame = panel.convert(panel.bounds, to: root)
        let panelRect = imageRect(for: panelFrame, in: root)
        if let image = cacheImage(of: panel), !isMostlyClear(image.rep) {
            return OverlayCapture(panel: panelRect, images: [(image.image, panelRect)])
        }

        var images: [(NSImage, NSRect)] = []
        func walk(_ view: NSView) {
            if view !== panel {
                let frame = view.convert(view.bounds, to: root)
                let area = frame.width * frame.height
                let intersection = panelFrame.intersection(frame)
                let inside = area > 1 && intersection.width * intersection.height >= area * 0.7
                if inside, view.bounds.width >= 8, view.bounds.height >= 8, !(view is NSVisualEffectView),
                   let image = cacheImage(of: view), !isMostlyClear(image.rep) {
                    images.append((image.image, imageRect(for: frame, in: root)))
                    return
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(panel)
        guard !images.isEmpty else { return nil }
        return OverlayCapture(panel: panelRect, images: images)
    }

    private static func overlayPanel(in root: NSView) -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            if found != nil { return }
            let frame = view.convert(view.bounds, to: root)
            let overlaysPage = frame.minX > 200 && frame.width >= 280 && frame.width <= 760
                && frame.height >= 44 && frame.height <= 560
            if overlaysPage, !(view is NSVisualEffectView) {
                found = view
                return
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    private static func cacheImage(of view: NSView) -> (image: NSImage, rep: NSBitmapImageRep)? {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return (image, rep)
    }

    /// True when the cache is empty or only a flat near-white fill. Text counts as ink.
    private static func isMostlyClear(_ rep: NSBitmapImageRep) -> Bool {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        if width < 2 || height < 2 { return true }
        var ink = 0
        var samples = 0
        let stepX = max(1, width / 40)
        let stepY = max(1, height / 40)
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                samples += 1
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent < 0.2 { continue }
                if color.redComponent < 0.93 || color.greenComponent < 0.93 || color.blueComponent < 0.93 {
                    ink += 1
                }
            }
        }
        return samples == 0 || Double(ink) / Double(samples) < 0.008
    }

    private static func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        var found: [NSVisualEffectView] = []
        if let effect = view as? NSVisualEffectView { found.append(effect) }
        for subview in view.subviews {
            found.append(contentsOf: visualEffectViews(in: subview))
        }
        return found
    }

    private static func mainWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 200 }
        if let key = NSApp.keyWindow, candidates.contains(where: { $0 === key }) { return key }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static var model: BrowserModel? { attachedModel }
}

/// Holds the distributed-notification callback. Not main-actor isolated: delivery can hop afterwards.
private final class SnapshotRelay: NSObject, @unchecked Sendable {
    let body: @Sendable (Notification) -> Void

    init(_ body: @escaping @Sendable (Notification) -> Void) {
        self.body = body
        super.init()
    }

    @objc func onNote(_ note: Notification) {
        body(note)
    }
}
#endif
