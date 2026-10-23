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
        // A private channel so a second debug build does not write this process's window
        // over the requested path. Either env var is accepted.
        var names = ["ch.marvinvr.mybrowser.debug.snapshot", "ch.marvinvr.mybrowser.debug.capture"]
        for key in ["MYBROWSER_DEBUG_SNAPSHOT_NAME", "MYBROWSER_DEBUG_SNAPSHOT_CHANNEL"] {
            if let extra = ProcessInfo.processInfo.environment[key], !extra.isEmpty {
                names.append(extra)
            }
        }
        for name in names {
            relays.append(observe(name) { note in
                let path = note.userInfo?["path"] as? String
                let window = note.userInfo?["window"] as? String
                Task { @MainActor in
                    await DebugSnapshot.capture(to: path, preferring: window)
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
        relays.append(observe("ch.marvinvr.mybrowser.debug.addressBar") { note in
            let raw = (note.userInfo?["position"] as? String)?.lowercased()
            Task { @MainActor in
                guard let raw, AddressBarPosition(rawValue: raw) != nil else { return }
                UserDefaults.standard.set(raw, forKey: AddressBarPosition.defaultsKey)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.space") { note in
            let name = note.userInfo?["name"] as? String
            let action = note.userInfo?["action"] as? String
            Task { @MainActor in
                guard let model = attachedModel else { return }
                if action == "new" {
                    let title = (name?.isEmpty == false ? name : nil) ?? "Space"
                    _ = model.createSpace(name: title, symbol: "circle.fill", color: .green)
                    return
                }
                guard let name, let space = model.library.orderedSpaces.first(where: { $0.name == name }) else { return }
                model.selectSpace(space.id)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.eval") { note in
            let script = note.userInfo?["script"] as? String
            let path = note.userInfo?["path"] as? String
            Task { @MainActor in
                guard let script, let path, path.hasPrefix("/") else { return }
                let result: String
                if let webView = attachedModel?.selectedTab?.webView {
                    do {
                        let value = try await webView.evaluateJavaScript(script)
                        result = String(describing: value ?? "nil")
                    } catch {
                        result = "error: \(error.localizedDescription)"
                    }
                } else {
                    result = "error: no web view"
                }
                try? result.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
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
    private static func capture(to path: String?, preferring titleHint: String? = nil) async {
        guard let path, path.hasPrefix("/") else { return }
        guard let window = targetWindow(preferring: titleHint), let content = window.contentView, content.bounds.width > 1, content.bounds.height > 1 else {
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
        // One sidebar image, and only when the window cache left that column blank.
        // Painting it on top of a cache that already has the column stacks translucent fills.
        let sidebarLimit = sidebarMaxX(in: content)
        let sidebar = sidebarRegionHasInk(cache, maxX: sidebarLimit, viewSize: bounds.size)
            ? []
            : sidebarImages(in: content, maxX: sidebarLimit)
        for item in savedEffects {
            item.view.material = item.material
            item.view.blendingMode = item.blending
        }

        // cacheDisplay leaves WKWebView blank, including an extension popup's page.
        var pages: [(NSImage, NSRect)] = []
        for webView in webViews(in: content) where webView.bounds.width > 1 && webView.bounds.height > 1 {
            let configuration = WKSnapshotConfiguration()
            guard let shot = try? await webView.takeSnapshot(configuration: configuration) else { continue }
            let frame = webView.convert(webView.bounds, to: content)
            pages.append((shot, imageRect(for: frame, in: content)))
        }
        let sheetImage = attachedSheetImage(on: window, content: content)
        let commandFill = commandBarFill(for: window)

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
        for (image, frame) in sidebar {
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        for (shot, frame) in pages {
            shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        if let sheet = sheetImage {
            // The sheet material cacheDisplays clear, so the title and buttons would sit on the page.
            let card = NSBezierPath(roundedRect: sheet.frame, xRadius: 12, yRadius: 12)
            sheet.fill.setFill()
            card.fill()
            sheet.image.draw(in: sheet.frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        if let overlay = overlayCapture(in: content) {
            // Glass often cacheDisplays as clear pixels. Paint a solid card in the
            // current appearance so the panel stays readable on the page.
            let card = NSBezierPath(roundedRect: overlay.panel, xRadius: 14, yRadius: 14)
            commandFill.setFill()
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

    private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        if let webView = view as? WKWebView { found.append(webView) }
        for subview in view.subviews {
            found.append(contentsOf: webViews(in: subview))
        }
        return found
    }

    private struct SheetCapture {
        var image: NSImage
        var frame: NSRect
        var fill: NSColor
    }

    /// An `NSAlert` sheet is a separate window. Draw it on top of the parent capture.
    private static func attachedSheetImage(on window: NSWindow, content: NSView) -> SheetCapture? {
        guard let sheet = window.attachedSheet, sheet !== window, let sheetContent = sheet.contentView,
              sheetContent.bounds.width > 1, sheetContent.bounds.height > 1 else { return nil }
        sheetContent.layoutSubtreeIfNeeded()
        guard let cached = cacheImage(of: sheetContent) else { return nil }
        let inWindow = sheetContent.convert(sheetContent.bounds, to: nil)
        let inScreen = sheet.convertToScreen(inWindow)
        let inParent = window.convertFromScreen(inScreen)
        let inContent = content.convert(inParent, from: nil)
        var fill = NSColor.windowBackgroundColor
        sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? NSColor.windowBackgroundColor
        }
        return SheetCapture(image: cached.image, frame: imageRect(for: inContent, in: content), fill: fill)
    }

    /// Solid stand-in for a glass command bar. Light stays near white; dark stays near the window.
    private static func commandBarFill(for window: NSWindow) -> NSColor {
        var dark = false
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return dark ? NSColor(deviceWhite: 0.2, alpha: 1) : NSColor(deviceWhite: 0.97, alpha: 1)
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

    /// True when the window cache already drew the sidebar, so a second pass would stack washes.
    private static func sidebarRegionHasInk(_ rep: NSBitmapImageRep, maxX: CGFloat, viewSize: NSSize) -> Bool {
        guard viewSize.width > 1, viewSize.height > 1, rep.pixelsWide > 8, rep.pixelsHigh > 8 else { return false }
        let scaleX = CGFloat(rep.pixelsWide) / viewSize.width
        let maxPixelX = max(4, min(rep.pixelsWide - 1, Int(maxX * scaleX)))
        var seen: Set<UInt32> = []
        let stepX = max(2, maxPixelX / 24)
        let stepY = max(2, rep.pixelsHigh / 36)
        for y in stride(from: stepY, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 2, to: maxPixelX, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.2 else { continue }
                let key = (UInt32(color.redComponent * 16) << 8)
                    | (UInt32(color.greenComponent * 16) << 4)
                    | UInt32(color.blueComponent * 16)
                seen.insert(key)
                if seen.count >= 6 { return true }
            }
        }
        return false
    }

    /// One image of the sidebar column when that cache has real pixels.
    /// Otherwise each leaf is drawn once. Ancestors are not also drawn, so a
    /// translucent fill is not stacked into a solid chip.
    private static func sidebarImages(in root: NSView, maxX limit: CGFloat) -> [(NSImage, NSRect)] {
        var best: (image: NSImage, frame: NSRect, area: CGFloat)?
        for column in sidebarColumns(in: root, maxX: limit) {
            guard let cached = cacheImage(of: column), visibleFraction(cached.rep) >= 0.08 else { continue }
            let frame = column.convert(column.bounds, to: root)
            let area = frame.width * frame.height
            if best == nil || area > best!.area {
                best = (cached.image, imageRect(for: frame, in: root), area)
            }
        }
        if let best { return [(best.image, best.frame)] }
        return sidebarLeaves(in: root, maxX: limit)
    }

    /// Left edge of the page. Sidebar views sit strictly to the left of it.
    /// Collapsed, the page starts at the window edge, so the hidden sidebar is skipped.
    private static func sidebarMaxX(in root: NSView) -> CGFloat {
        var cardMinX = root.bounds.width
        func walk(_ view: NSView) {
            if view is WKWebView {
                let frame = view.convert(view.bounds, to: root)
                if frame.width > 200, frame.minX >= 0 {
                    cardMinX = min(cardMinX, frame.minX)
                }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        if cardMinX < root.bounds.width - 80 { return cardMinX - 1 }
        return min(420, root.bounds.width)
    }

    /// Tall views that fill the sidebar column and nothing to the right of the page.
    private static func sidebarColumns(in root: NSView, maxX limit: CGFloat) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view.isHidden || view.alphaValue <= 0.01 || view is NSVisualEffectView {
                for subview in view.subviews { walk(subview) }
                return
            }
            let frame = view.convert(view.bounds, to: root)
            let column = frame.minX < 16 && frame.maxX <= limit + 4
                && frame.width >= 140 && frame.height > root.bounds.height * 0.7
            if column { found.append(view) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    /// Leaf caches only. A parent that also draws its children is not included.
    private static func sidebarLeaves(in root: NSView, maxX limit: CGFloat) -> [(NSImage, NSRect)] {
        var images: [(NSImage, NSRect)] = []
        func walk(_ view: NSView) {
            if view.isHidden || view.alphaValue <= 0.01 { return }
            if view is NSVisualEffectView {
                for subview in view.subviews { walk(subview) }
                return
            }
            if view.subviews.isEmpty {
                let frame = view.convert(view.bounds, to: root)
                let inSidebar = frame.width >= 4 && frame.height >= 4
                    && frame.minX >= -2 && frame.maxX <= limit + 1 && frame.minX < limit
                if inSidebar, let cached = cacheImage(of: view), visibleFraction(cached.rep) >= 0.02 {
                    images.append((cached.image, imageRect(for: frame, in: root)))
                }
                return
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return images
    }

    /// Share of samples that are more than a hairline opaque. A 12% wash counts; clear glass does not.
    private static func visibleFraction(_ rep: NSBitmapImageRep) -> Double {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        if width < 2 || height < 2 { return 0 }
        var hit = 0
        var samples = 0
        let stepX = max(1, width / 32)
        let stepY = max(1, height / 32)
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                samples += 1
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent >= 0.04 { hit += 1 }
            }
        }
        guard samples > 0 else { return 0 }
        return Double(hit) / Double(samples)
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

    private static func targetWindow(preferring titleHint: String?) -> NSWindow? {
        var candidates = NSApp.windows.filter { window in
            guard window.isVisible, window.contentView != nil else { return false }
            if window.frame.width > 200 { return true }
            let identifier = window.identifier?.rawValue ?? ""
            return identifier.contains("extension-popup") || identifier.contains("extension-permission")
        }
        for window in NSApp.windows {
            guard let sheet = window.attachedSheet, sheet.contentView != nil else { continue }
            if !candidates.contains(where: { $0 === sheet }) {
                candidates.append(sheet)
            }
        }
        if let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hint.isEmpty {
            if hint.contains("permission") || hint.contains("access") {
                if let sheet = candidates.first(where: { window in
                    let identifier = window.identifier?.rawValue.lowercased() ?? ""
                    return window.sheetParent != nil
                        || identifier.contains("extension-permission")
                        || window.title.lowercased().contains("extension access")
                }) {
                    return sheet
                }
            }
            if let match = candidates.first(where: { window in
                window.title.lowercased().contains(hint)
                    || window.identifier?.rawValue.lowercased().contains(hint) == true
            }) {
                return match
            }
            if hint == "settings" {
                let settings = candidates.filter { window in
                    let area = window.frame.width * window.frame.height
                    return window.frame.width < 700 && window.frame.height < 600 && area > 40_000
                }
                if let match = settings.min(by: { $0.frame.width < $1.frame.width }) {
                    return match
                }
            }
        }
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
