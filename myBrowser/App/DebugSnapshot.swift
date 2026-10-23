#if DEBUG
import AppKit
import Vision
import WebKit

/// DEBUG-only window capture. Draws the window in-process. Prefer `screencapture` when the terminal can record the screen; glass effects do not appear in this bitmap.
///
/// `ch.marvinvr.mybrowser.debug.snapshot` — userInfo["path"] is an absolute PNG path.
enum DebugSnapshot {
    private static var relays: [SnapshotRelay] = []
    private static weak var attachedModel: BrowserModel?

    static func install(model: BrowserModel) {
        attachedModel = model
        guard relays.isEmpty else { return }
        register(model: model)
    }

    /// Extension load stops distributed notifications from arriving. Register again afterwards.
    static func reregister() {
        let center = DistributedNotificationCenter.default()
        for relay in relays {
            center.removeObserver(relay)
        }
        relays.removeAll()
        guard let model = attachedModel else { return }
        register(model: model)
    }

    private static func register(model: BrowserModel) {
        _ = model
        // `.capture` is the same shot as `.snapshot`. Snapshot scripts can use it when another
        // debug build is already listening for `.snapshot`.
        // A private channel so a second debug build does not write this process's window
        // over the requested path. Either env var is accepted.
        // A private channel opts out of the shared names. Other debug builds post those
        // during launch, and handling one inside didFinishLaunching crashes SwiftUI.
        let privateChannel = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_SNAPSHOT_CHANNEL"]
        let privateName = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_SNAPSHOT_NAME"]
        var names: [String] = []
        if (privateChannel == nil || privateChannel?.isEmpty == true),
           (privateName == nil || privateName?.isEmpty == true) {
            names = ["ch.marvinvr.mybrowser.debug.snapshot", "ch.marvinvr.mybrowser.debug.capture"]
        }
        for key in ["MYBROWSER_DEBUG_SNAPSHOT_NAME", "MYBROWSER_DEBUG_SNAPSHOT_CHANNEL"] {
            if let extra = ProcessInfo.processInfo.environment[key], !extra.isEmpty, !names.contains(extra) {
                names.append(extra)
            }
        }
        for name in names {
            relays.append(observe(name) { note in
                let info = note.userInfo
                if let ack = info?["ack"] as? String {
                    Self.writeDebug("ok", to: ack)
                }
                if let script = info?["script"] as? String, let path = info?["path"] as? String {
                    Self.writeDebug("pending", to: path)
                    let popup = (info?["popupScript"] as? String) == "1"
                    Task { @MainActor in
                        let result: String
                        let webView = popup
                            ? DebugSnapshot.extensionPopupWebView()
                            : attachedModel?.selectedTab?.webView
                        if let webView {
                            result = await DebugSnapshot.evalOrTimeout(webView, script: script)
                        } else {
                            result = popup ? "error: no popup" : "error: no web view"
                        }
                        Self.writeDebug(result, to: path)
                    }
                    return
                }
                if let raw = info?["url"] as? String, let url = URL(string: raw),
                   let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    Task { @MainActor in
                        attachedModel?.openInCurrentTab(url)
                    }
                    return
                }
                if info?["popup"] as? String == "1" {
                    let extensionID = (info?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
                    Task { @MainActor in
                        guard let model = attachedModel, let profileID = model.selectedSpace?.profileID else { return }
                        model.extensions?.performAction(extensionID: extensionID, profileID: profileID, tab: model.selectedTab)
                    }
                    return
                }
                if info?["settings"] as? String == "1" {
                    Task { @MainActor in
                        NSApp.activate(ignoringOtherApps: true)
                        if let item = Self.menuItem(containing: "Settings") ?? Self.menuItem(containing: "Preferences") {
                            NSApp.sendAction(item.action ?? Selector(("showSettingsWindow:")), to: item.target, from: item)
                        } else {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        }
                    }
                    return
                }
                if let mode = (info?["appearance"] as? String)?.lowercased() {
                    Task { @MainActor in
                        switch mode {
                        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                        case "light": NSApp.appearance = NSAppearance(named: .aqua)
                        default: break
                        }
                        attachedModel?.selectedTab?.refreshThemeColor()
                    }
                    return
                }
                let path = (info?["path"] as? String).map(Self.debugPath)
                let window = info?["window"] as? String
                let windows = info?["windows"] as? String
                Task { @MainActor in
                    if windows == "all" {
                        DebugSnapshot.captureOwnedWindows(to: path)
                    } else {
                        await DebugSnapshot.capture(to: path, preferring: window)
                    }
                }
            })
        }
        if let library = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"], !library.isEmpty {
            let note = names.joined(separator: "\n") + "\n"
            let url = URL(fileURLWithPath: library, isDirectory: true).appendingPathComponent("debug-channels.txt")
            try? note.write(to: url, atomically: true, encoding: .utf8)
        }
        relays.append(observe("ch.marvinvr.mybrowser.debug.open") { note in
            guard Self.addressedToThisProcess(note) else { return }
            let raw = note.userInfo?["url"] as? String
            Task { @MainActor in
                guard let raw, let url = URL(string: raw) else { return }
                attachedModel?.openInCurrentTab(url)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.reload") { note in
            guard Self.addressedToThisProcess(note) else { return }
            Task { @MainActor in
                attachedModel?.selectedTab?.reload()
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.appearance") { note in
            guard Self.addressedToThisProcess(note) else { return }
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
        relays.append(observe("ch.marvinvr.mybrowser.debug.copy") { note in
            guard Self.addressedToThisProcess(note) else { return }
            Task { @MainActor in
                attachedModel?.copyCurrentLink()
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.addressBar") { note in
            guard Self.addressedToThisProcess(note) else { return }
            let raw = (note.userInfo?["position"] as? String)?.lowercased()
            Task { @MainActor in
                guard let raw, AddressBarPosition(rawValue: raw) != nil else { return }
                UserDefaults.standard.set(raw, forKey: AddressBarPosition.defaultsKey)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.space") { note in
            guard Self.addressedToThisProcess(note) else { return }
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
        relays.append(observe("ch.marvinvr.mybrowser.debug.spaceSwitch") { note in
            guard Self.addressedToThisProcess(note) else { return }
            let action = note.userInfo?["action"] as? String ?? "click"
            let clip = note.userInfo?["clip"] as? String
            Task { @MainActor in
                guard let model = attachedModel else { return }
                await DebugSnapshot.measureSpaceSwitch(action: action, clip: clip, model: model)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.eval") { note in
            guard Self.addressedToThisProcess(note) else { return }
            let script = note.userInfo?["script"] as? String
            let path = (note.userInfo?["path"] as? String).map(Self.debugPath)
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
        relays.append(observe("ch.marvinvr.mybrowser.debug.frames") { note in
            guard Self.addressedToThisProcess(note) else { return }
            let dir = note.userInfo?["dir"] as? String
            let count = Self.intValue(note.userInfo?["count"]) ?? 20
            let interval = Self.intValue(note.userInfo?["interval"]) ?? 16
            Task { @MainActor in
                await DebugSnapshot.recordFrames(directory: dir, count: count, interval: interval)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.popup") { note in
            guard Self.addressedToThisProcess(note) else { return }
            let path = note.userInfo?["path"] as? String
            Task { @MainActor in
                DebugSnapshot.captureOpenArchivePopup(to: path)
            }
        })
        relays.append(observe("ch.marvinvr.mybrowser.debug.command") { note in
            guard Self.addressedToThisProcess(note) else { return }
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
        // Private channel so a PiP test does not drive every other debug build on the machine.
        if let control = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_CONTROL"], !control.isEmpty {
            relays.append(observe(control) { note in
                let info = note.userInfo ?? [:]
                let action = info["action"] as? String ?? ""
                let rawURL = info["url"] as? String
                let script = info["script"] as? String
                let path = info["path"] as? String
                let name = (info["arg"] as? String) ?? (info["name"] as? String)
                Task { @MainActor in
                    DebugSnapshot.performControl(
                        action: action,
                        rawURL: rawURL,
                        script: script,
                        path: path,
                        name: name
                    )
                }
            })
        }
    }

    @MainActor
    private static func performControl(
        action: String,
        rawURL: String?,
        script: String?,
        path: String?,
        name: String?
    ) {
        guard let model = attachedModel else { return }
        switch action {
        case "open":
            guard let rawURL, let url = URL(string: rawURL) else { return }
            model.openInCurrentTab(url)
        case "newtab":
            guard let rawURL, let url = URL(string: rawURL) else { return }
            model.openInNewTab(url)
        case "selecturl":
            guard let rawURL, let url = URL(string: rawURL) else { return }
            let wanted = url.absoluteString
            if let item = model.library.items.values.first(where: {
                $0.deletedAt == nil && $0.kind == .site && $0.url?.absoluteString == wanted
            }) {
                model.select(item.id)
            }
        case "pip":
            model.togglePictureInPicture()
        case "release":
            // The system panel's return control leaves PiP without our suppress flag.
            // This drives that same page-side exit so the focus policy can be checked headless.
            if let id = model.pictureInPictureTabID, let tab = model.tabs[id] {
                tab.webView.map { webView in
                    PictureInPictureWebKit.evaluate(
                        webView,
                        frame: nil,
                        script: "window.__myBrowserPiP ? window.__myBrowserPiP.exit() : 'missing'"
                    ) { _ in }
                }
            }
        case "prev":
            model.selectPreviousTab()
        case "next":
            model.selectNextTab()
        case "space":
            let which = name ?? rawURL
            if which == "new" {
                _ = model.createSpace(name: "Elsewhere", symbol: "circle.fill", color: .green)
            } else if let which, let space = model.library.orderedSpaces.first(where: { $0.name == which }) {
                model.selectSpace(space.id)
            }
        case "hide":
            NSApp.hide(nil)
        case "show":
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            browserWindowForPictureInPicture()?.makeKeyAndOrderFront(nil)
        case "appearance":
            switch name {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
            model.selectedTab?.refreshThemeColor()
        case "downloads":
            switch name {
            case "popover": model.downloads.isPopoverPresented = true
            case "close": model.downloads.isPopoverPresented = false
            case "page": model.downloads.isPagePresented = true
            case "hide-page": model.downloads.isPagePresented = false
            default: break
            }
            if let path, path.hasPrefix("/") {
                try? model.downloads.debugSummary().write(
                    to: URL(fileURLWithPath: path),
                    atomically: true,
                    encoding: .utf8
                )
            }
        case "state":
            guard let path, path.hasPrefix("/") else { return }
            let tab = model.selectedTab
            let text = [
                "can=\(model.canPictureInPicture)",
                "active=\(model.pictureInPictureActive)",
                "session=\(model.pictureInPictureTabID?.uuidString ?? "-")",
                "selected=\(tab?.url?.absoluteString ?? "")",
                "title=\(tab?.title ?? "")",
                "video=\(tab?.hasPictureInPictureVideo == true)",
                "pip=\(tab?.isPictureInPictureActive == true)",
            ].joined(separator: "\n")
            try? text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        case "eval":
            guard let script, let path, path.hasPrefix("/") else { return }
            Task { @MainActor in
                let result: String
                if let webView = model.selectedTab?.webView {
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
        default:
            break
        }
    }

    /// A note that carries `channel` is for one debug build.
    /// A process with `MYBROWSER_DEBUG_SNAPSHOT_CHANNEL` or `MYBROWSER_DEBUG_SNAPSHOT_NAME`
    /// ignores every other note, including unscoped ones, so a second debug app's
    /// `debug.open` cannot navigate this tab. A process with neither set still accepts
    /// unscoped notes, which is what the single-app snapshot scripts send.
    nonisolated private static func addressedToThisProcess(_ note: Notification) -> Bool {
        let env = ProcessInfo.processInfo.environment
        let channels = ["MYBROWSER_DEBUG_SNAPSHOT_CHANNEL", "MYBROWSER_DEBUG_SNAPSHOT_NAME"].compactMap { env[$0] }
        return DebugNoteRouting.accepts(noteChannel: note.userInfo?["channel"] as? String, processChannels: channels)
    }

    private static func menuItem(containing needle: String) -> NSMenuItem? {
        func walk(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title.localizedCaseInsensitiveContains(needle) { return item }
                if let found = walk(item.submenu) { return found }
            }
            return nil
        }
        return walk(NSApp.mainMenu)
    }

    /// `{pid}` in a debug path becomes this process id, so several debug builds do not share one file.
    nonisolated private static func debugPath(_ path: String) -> String {
        path.replacingOccurrences(of: "{pid}", with: String(ProcessInfo.processInfo.processIdentifier))
    }

    nonisolated private static func writeDebug(_ text: String, to path: String) {
        let path = debugPath(path)
        guard path.hasPrefix("/") else { return }
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Page JavaScript can stall when an extension content script is busy. Always return.
    @MainActor
    private static func evalOrTimeout(_ webView: WKWebView, script: String) async -> String {
        let once = OnceBox()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let result: String
                do {
                    let value = try await webView.evaluateJavaScript(script)
                    result = String(describing: value ?? "nil")
                } catch {
                    result = "error: \(error.localizedDescription)"
                }
                if once.claim() { continuation.resume(returning: result) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if once.claim() { continuation.resume(returning: "error: timed out") }
            }
        }
    }

    /// `takeSnapshot` can stall on a heavy extension page. Skip that web view and keep the chrome.
    @MainActor
    private static func snapshotOrTimeout(_ webView: WKWebView) async -> NSImage? {
        let once = OnceBox()
        let box = SnapshotImageBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                let configuration = WKSnapshotConfiguration()
                box.image = try? await webView.takeSnapshot(configuration: configuration)
                if once.claim() { continuation.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if once.claim() { continuation.resume() }
            }
        }
        return box.image
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

    /// Paints two spaces and replays a click or a sidebar swipe. Writes `prepared` / `clicked` / `swiped`
    /// under `/tmp/my-browser-shots/space-switch/` when that step finishes.
    @MainActor
    private static func measureSpaceSwitch(action: String, clip: String?, model: BrowserModel) async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }) {
            window.makeKeyAndOrderFront(nil)
        }
        switch action {
        case "prepare":
            await prepareSpaceSwitchMeasure(model)
            writeSpaceSwitchReady("prepared")
        case "click":
            let recording = clip.map { directory in
                Task { await recordFrames(directory: directory, count: 24, interval: 16) }
            }
            try? await Task.sleep(for: .milliseconds(48))
            SpaceSwitchTrace.mark("measure-click")
            model.selectNextSpace()
            await recording?.value
            writeSpaceSwitchReady("clicked")
        case "swipe":
            await replaySpaceSwipe(model: model, clip: clip)
            writeSpaceSwitchReady("swiped")
        default:
            break
        }
    }

    @MainActor
    private static func prepareSpaceSwitchMeasure(_ model: BrowserModel) async {
        if model.library.orderedSpaces.count < 2 {
            _ = model.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)
        }
        let spaces = Array(model.library.orderedSpaces.prefix(2))
        let pages = [("Alpha", "#c0392b"), ("Beta", "#1a5276")]
        let directory = URL(fileURLWithPath: "/tmp/my-browser-shots/space-switch", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (space, page) in zip(spaces, pages) {
            model.selectSpace(space.id)
            if model.selectedTab == nil {
                let item = model.library.addItem(
                    spaceID: space.id,
                    section: .tabs,
                    title: page.0,
                    url: URL(string: "https://example.com/\(page.0)")
                )
                model.select(item.id)
            }
            let html = """
            <html><head><title>\(page.0)</title></head>
            <body style="margin:0;background:\(page.1);color:white;font:96px -apple-system,sans-serif">
            <div style="padding:72px">\(page.0)</div></body></html>
            """
            let file = directory.appending(path: "\(page.0).html")
            try? html.write(to: file, atomically: true, encoding: .utf8)
            model.selectedTab?.load(file)
        }
        if let first = spaces.first {
            model.selectSpace(first.id)
        }
        model.prewarmNeighbourSpaces()
        try? await Task.sleep(for: .milliseconds(700))
    }

    @MainActor
    private static func replaySpaceSwipe(model: BrowserModel, clip: String?) async {
        let recording = clip.map { directory in
            Task { await recordFrames(directory: directory, count: 60, interval: 16) }
        }
        try? await Task.sleep(for: .milliseconds(32))
        SpaceSwitchTrace.mark("measure-swipe")
        var time = CACurrentMediaTime()
        SpaceSwipeDebugInject.send?(SpaceSwipeSample(phase: .began, deltaX: 0, deltaY: 0, time: time))
        for _ in 0..<10 {
            time += 0.02
            SpaceSwipeDebugInject.send?(
                SpaceSwipeSample(phase: .changed, deltaX: -28, deltaY: 0, time: time)
            )
            try? await Task.sleep(for: .milliseconds(20))
        }
        time += 0.02
        SpaceSwipeDebugInject.send?(SpaceSwipeSample(phase: .ended, deltaX: 0, deltaY: 0, time: time))
        try? await Task.sleep(for: .milliseconds(520))
        await recording?.value
    }

    private static func writeSpaceSwitchReady(_ name: String) {
        let url = URL(fileURLWithPath: "/tmp/my-browser-shots/space-switch/\(name)", isDirectory: false)
        try? Data("ok\n".utf8).write(to: url)
    }

    /// Composited window frames. `CGWindowListCreateImage` is unavailable to other processes here,
    /// but the app can still read its own window. Used to record sidebar motion.
    @MainActor
    private static func recordFrames(directory: String?, count: Int, interval: Int) async {
        guard let directory, directory.hasPrefix("/") else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frames = min(max(count, 1), 60)
        let step = max(interval, 8)
        for index in 0..<frames {
            let started = Date()
            let image: CGImage?
            if let windowImage = ownWindowImage(), frameHasInk(windowImage) {
                image = windowImage
            } else {
                // The window server sometimes returns a full-size black bitmap.
                // Draw the chrome and each visible page instead.
                image = await composedFrame()
            }
            if let image {
                let url = folder.appendingPathComponent(String(format: "f%02d.png", index))
                Task.detached {
                    let rep = NSBitmapImageRep(cgImage: image)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: url)
                    }
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            let remaining = Double(step) / 1000 - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// A refused window-server capture is a full-size black image, not nil.
    private static func frameHasInk(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        let samples = [
            (image.width / 2, image.height / 2),
            (image.width / 5, image.height / 3),
            (image.width * 3 / 4, image.height / 2),
        ]
        for (x, y) in samples {
            guard let color = rep.colorAt(x: x, y: y) else { continue }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: nil)
            if red > 0.02 || green > 0.02 || blue > 0.02 { return true }
        }
        return false
    }

    /// Chrome from `cacheDisplay`, pages from `takeSnapshot`, placed at their current frames.
    private static func composedFrame() async -> CGImage? {
        guard let window = targetWindow(preferring: nil),
              let content = window.contentView,
              content.bounds.width > 1, content.bounds.height > 1 else { return nil }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        let scale = window.backingScaleFactor
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let cache = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        output.size = bounds.size
        content.cacheDisplay(in: bounds, to: cache)
        let chrome = NSImage(size: bounds.size)
        chrome.addRepresentation(cache)

        var pages: [(NSImage, NSRect)] = []
        for webView in webViews(in: content) where webView.bounds.width > 2 && webView.bounds.height > 2 && !webView.isHidden {
            let frame = webView.convert(webView.bounds, to: content)
            let visible = frame.intersection(bounds)
            guard visible.width > 8, visible.height > bounds.height * 0.4 else { continue }
            guard let shot = await snapshotOrTimeout(webView) else { continue }
            pages.append((shot, imageRect(for: frame, in: content)))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        chrome.draw(in: NSRect(origin: .zero, size: bounds.size), from: .zero, operation: .sourceOver, fraction: 1)
        for (shot, frame) in pages {
            shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return output.cgImage
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Every on-screen window of this process, including a context menu.
    /// `screencapture` cannot read these windows from outside the app.
    @MainActor
    static func captureOwnedWindows(to path: String?) {
        guard let path, path.hasPrefix("/") else { return }
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY), "CGWindowListCreateImage") else {
            return
        }
        let create = unsafeBitCast(symbol, to: Create.self)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        struct Shot {
            var image: CGImage
            var bounds: CGRect
        }
        var shots: [Shot] = []
        for item in info {
            guard (item[kCGWindowOwnerPID as String] as? Int) == pid else { continue }
            guard let number = item[kCGWindowNumber as String] as? Int, number > 0 else { continue }
            guard let raw = item[kCGWindowBounds as String] as? [String: Any] else { continue }
            let bounds = CGRect(
                x: (raw["X"] as? NSNumber)?.doubleValue ?? 0,
                y: (raw["Y"] as? NSNumber)?.doubleValue ?? 0,
                width: (raw["Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (raw["Height"] as? NSNumber)?.doubleValue ?? 0
            )
            guard bounds.width > 8, bounds.height > 8 else { continue }
            let includingWindow: UInt32 = 1 << 3
            let options: UInt32 = (1 << 0) | (1 << 3)
            guard let image = create(.null, includingWindow, UInt32(number), options)?.takeRetainedValue() else { continue }
            guard image.width > 8, image.height > 8 else { continue }
            shots.append(Shot(image: image, bounds: bounds))
        }
        guard let first = shots.first else { return }
        var union = first.bounds
        for shot in shots.dropFirst() { union = union.union(shot.bounds) }
        guard union.width > 1, union.height > 1 else { return }
        let scale = CGFloat(first.image.width) / max(first.bounds.width, 1)
        let pixelsWide = max(1, Int((union.width * scale).rounded(.up)))
        let pixelsHigh = max(1, Int((union.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor(gray: 0, alpha: 0))
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        // The window list is front to back. Draw the back window first so a menu stays on top.
        for shot in shots.reversed() {
            let dest = CGRect(
                x: (shot.bounds.minX - union.minX) * scale,
                y: (union.maxY - shot.bounds.maxY) * scale,
                width: shot.bounds.width * scale,
                height: shot.bounds.height * scale
            )
            context.draw(shot.image, in: dest)
        }
        guard let composed = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Own-window composite. Returns nil when the window server refuses the capture.
    private static func ownWindowImage() -> CGImage? {
        guard let window = targetWindow(preferring: nil), window.windowNumber > 0 else { return nil }
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY), "CGWindowListCreateImage") else {
            return nil
        }
        let create = unsafeBitCast(symbol, to: Create.self)
        let includingWindow: UInt32 = 1 << 3
        let options: UInt32 = (1 << 0) | (1 << 3)
        return create(.null, includingWindow, UInt32(window.windowNumber), options)?.takeRetainedValue()
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
        // The page image is then painted over the pane, which hides controls that sit
        // on top of it (the split hover pill). Those smaller siblings are drawn again after.
        var pages: [(NSImage, NSRect)] = []
        var pageChrome: [(NSImage, NSRect)] = []
        for webView in webViews(in: content) where webView.bounds.width > 1 && webView.bounds.height > 1 {
            guard let shot = await snapshotOrTimeout(webView) else { continue }
            let frame = webView.convert(webView.bounds, to: content)
            pages.append((shot, imageRect(for: frame, in: content)))
            guard let parent = webView.superview, let index = parent.subviews.firstIndex(of: webView) else { continue }
            for sibling in parent.subviews.dropFirst(index + 1) {
                guard !sibling.isHidden, sibling.alphaValue > 0.01 else { continue }
                let coversPage = sibling.bounds.width > webView.bounds.width * 0.85
                    && sibling.bounds.height > webView.bounds.height * 0.85
                if coversPage { continue }
                appendChrome(sibling, to: &pageChrome, content: content)
            }
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
        for (image, frame) in pageChrome {
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
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
        for panel in childPanels(on: window, content: content) {
            let card = NSBezierPath(roundedRect: panel.frame, xRadius: 12, yRadius: 12)
            panel.fill.setFill()
            card.fill()
            panel.image.draw(in: panel.frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let data = output.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func appendChrome(
        _ sibling: NSView,
        to pageChrome: inout [(NSImage, NSRect)],
        content: NSView
    ) {
        guard let rep = sibling.bitmapImageRepForCachingDisplay(in: sibling.bounds) else { return }
        sibling.cacheDisplay(in: sibling.bounds, to: rep)
        let image = NSImage(size: sibling.bounds.size)
        image.addRepresentation(rep)
        let chromeFrame = sibling.convert(sibling.bounds, to: content)
        pageChrome.append((image, imageRect(for: chromeFrame, in: content)))
    }

    /// The extension action popover. Its page is not the selected tab.
    private static func extensionPopupWebView() -> WKWebView? {
        for window in NSApp.windows {
            let identifier = window.identifier?.rawValue.lowercased() ?? ""
            let title = window.title.lowercased()
            let popup = identifier.contains("extension-popup")
                || title.contains("extension popup")
                || title == "1password"
            guard popup, let content = window.contentView else { continue }
            if let webView = webViews(in: content).first(where: { $0.bounds.width > 1 && $0.bounds.height > 1 }) {
                return webView
            }
        }
        return nil
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

    /// Popovers are child windows. Draw them onto the main-window bitmap so a snapshot includes the downloads list.
    private static func childPanels(on window: NSWindow, content: NSView) -> [SheetCapture] {
        var panels = window.childWindows ?? []
        for other in NSApp.windows where other !== window && other.isVisible && other.parent === window {
            if !panels.contains(where: { $0 === other }) {
                panels.append(other)
            }
        }
        if let sheet = window.attachedSheet {
            panels.removeAll { $0 === sheet }
        }
        var captures: [SheetCapture] = []
        for panel in panels {
            guard let panelContent = panel.contentView, panelContent.bounds.width > 1, panelContent.bounds.height > 1 else { continue }
            panelContent.layoutSubtreeIfNeeded()
            guard let cached = cacheImage(of: panelContent) else { continue }
            let inWindow = panelContent.convert(panelContent.bounds, to: nil)
            let inScreen = panel.convertToScreen(inWindow)
            let inParent = window.convertFromScreen(inScreen)
            let inContent = content.convert(inParent, from: nil)
            var fill = NSColor.windowBackgroundColor
            panel.effectiveAppearance.performAsCurrentDrawingAppearance {
                fill = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? NSColor.windowBackgroundColor
            }
            captures.append(SheetCapture(image: cached.image, frame: imageRect(for: inContent, in: content), fill: fill))
        }
        return captures
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
                    return window.frame.width < 800 && window.frame.height < 780 && area > 40_000
                }
                if let match = settings.min(by: { $0.frame.width < $1.frame.width }) {
                    return match
                }
            }
        }
        if let key = NSApp.keyWindow, candidates.contains(where: { $0 === key }) { return key }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Opens the Archive tabs popup and writes a PNG of the settings window with that menu.
    /// SwiftUI draws the picker without an `NSPopUpButton`. The row is found by reading the
    /// window, then a common-mode timer grabs the menu while it is tracking.
    static func captureOpenArchivePopup(to path: String?) {
        guard let path, path.hasPrefix("/") else { return }
        guard let settings = settingsWindow() else {
            logLine("archive settings window not found")
            for window in NSApp.windows {
                logLine("window title=\(window.title) id=\(window.identifier?.rawValue ?? "") frame=\(window.frame)")
            }
            return
        }
        if let raw = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_WINDOW_X"], let x = Double(raw) {
            var frame = settings.frame
            frame.origin.x = x
            settings.setFrame(frame, display: true)
        }
        settings.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let content = settings.contentView,
              let local = viewRect(matching: "24 hours", in: content) else {
            logLine("archive popup text not found in settings")
            return
        }
        let button = settings.convertToScreen(content.convert(local, to: nil))
        guard let prepared = settingsShot(settings) else {
            logLine("archive settings raster failed")
            return
        }
        pendingSettingsImage = prepared.image
        pendingSettingsFrame = prepared.frame
        pendingButtonFrame = button
        logLine("archive popup text at \(button) flipped=\(content.isFlipped)")
        let shot = PopupShot(path: path)
        let timer = Timer(timeInterval: 0.55, repeats: false) { _ in
            shot.fire()
        }
        RunLoop.main.add(timer, forMode: .common)
        clickDown(settings, atScreen: button)
    }

    private static var pendingSettingsImage: NSImage?
    private static var pendingSettingsFrame: NSRect = .zero
    private static var pendingButtonFrame: NSRect = .zero

    /// View rect of the first recognized line that contains `needle`.
    private static func viewRect(matching needle: String, in view: NSView) -> NSRect? {
        guard let image = raster(of: view),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        logLine("vision scanning \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logLine("vision \(error.localizedDescription)")
            return nil
        }
        let observations = request.results ?? []
        let strings = observations.compactMap { $0.topCandidates(1).first?.string }
        logLine("vision \(strings.joined(separator: " | "))")
        guard let match = observations.first(where: { observation in
            let text = observation.topCandidates(1).first?.string ?? ""
            return text.localizedCaseInsensitiveContains(needle)
        }) else { return nil }
        let box = match.boundingBox
        let bounds = view.bounds
        let rect = NSRect(
            x: box.minX * bounds.width,
            y: box.minY * bounds.height,
            width: max(box.width * bounds.width, 24),
            height: max(box.height * bounds.height, 16)
        )
        guard view.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func settingsShot(_ settings: NSWindow) -> (image: NSImage, frame: NSRect)? {
        // cacheDisplay keeps the form. A window-server image of this window comes back blank here.
        if let content = settings.contentView,
           let image = raster(of: content),
           let frame = screenFrame(of: content) {
            return (image, frame)
        }
        guard let cg = cgWindowImage(settings.windowNumber) else { return nil }
        return (NSImage(cgImage: cg, size: settings.frame.size), settings.frame)
    }

    private static func logLine(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func settingsWindow() -> NSWindow? {
        let windows = NSApp.windows.filter { $0.contentView != nil }
        if let general = windows.first(where: { $0.title == "General" }) { return general }
        return windows.first { window in
            window.identifier?.rawValue.contains("Settings") == true
        }
    }

    fileprivate static func writeOpenPopup(to path: String) {
        guard let settings = settingsWindow(), let base = pendingSettingsImage else {
            logLine("popup shot: settings window missing")
            return
        }
        var shots: [(NSImage, NSRect)] = [(base, pendingSettingsFrame)]
        let button = pendingButtonFrame
        if button.width > 1, let menu = realMenuShot(besides: settings, near: button) {
            shots.append(menu)
            logLine("popup shot: real menu \(menu.1)")
        } else if button.width > 1 {
            let titles = TabArchiveInterval.allCases.map(\.label)
            let selected = TabArchiveInterval.twentyFourHours.label
            let menuImage = syntheticMenu(titles: titles, selected: selected, appearance: settings.effectiveAppearance)
            let menuFrame = NSRect(
                x: button.minX,
                y: button.minY - menuImage.size.height - 4,
                width: menuImage.size.width,
                height: menuImage.size.height
            )
            shots.append((menuImage, menuFrame))
            logLine("popup shot: synthetic menu \(menuFrame)")
        }
        guard let image = composite(shots) else { return }
        writePNG(image, to: path)
        pendingSettingsImage = nil
        logLine("popup shot wrote \(path)")
    }

    fileprivate static func dismissPopup() {
        if let settings = settingsWindow(),
           let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 8, y: 8),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: settings.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
           ) {
            settings.sendEvent(up)
        }
        func postKey(_ type: NSEvent.EventType, keyDown: Bool) {
            if let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            ) {
                NSApp.postEvent(event, atStart: true)
            }
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
        }
        postKey(.keyDown, keyDown: true)
        postKey(.keyUp, keyDown: false)
    }

    private static func clickDown(_ window: NSWindow, atScreen rect: NSRect) {
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return }
        window.sendEvent(down)
        logLine("clicked popup at \(point)")
    }

    private static func realMenuShot(besides settings: NSWindow, near button: NSRect?) -> (NSImage, NSRect)? {
        let menus = NSApp.windows.filter { window in
            guard window !== settings, window.isVisible else { return false }
            let frame = window.frame
            guard frame.width >= 70, frame.width <= 460, frame.height >= 80, frame.height <= 380 else { return false }
            guard let button else { return true }
            let horizontallyNear = abs(frame.midX - button.midX) < 260
            let verticallyNear = frame.maxY <= button.maxY + 12 && frame.minY >= button.minY - frame.height - 80
            return horizontallyNear && verticallyNear
        }
        if let menu = menus.first {
            if let content = menu.contentView, let image = raster(of: content), let frame = screenFrame(of: content) {
                return (image, frame)
            }
            if let image = cgWindowImage(menu.windowNumber) {
                return (NSImage(cgImage: image, size: menu.frame.size), menu.frame)
            }
        }
        for item in ownedOnScreenWindows() where Int(item.number) != settings.windowNumber {
            let frame = appKitFrame(fromAX: item.bounds)
            guard frame.width >= 70, frame.width <= 460, frame.height >= 80, frame.height <= 380 else { continue }
            if let button, abs(frame.midX - button.midX) > 260 { continue }
            guard let image = cgWindowImage(Int(item.number)) else { continue }
            return (NSImage(cgImage: image, size: frame.size), frame)
        }
        return nil
    }

    private static func ownedOnScreenWindows() -> [(number: UInt32, bounds: CGRect)] {
        typealias CopyInfo = @convention(c) (UInt32, UInt32) -> Unmanaged<CFArray>?
        guard let symbol = dlsym(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY), "CGWindowListCopyWindowInfo") else {
            return []
        }
        let copy = unsafeBitCast(symbol, to: CopyInfo.self)
        guard let array = copy(1, 0)?.takeRetainedValue() else { return [] }
        let pid = Int32(getpid())
        guard let infos = array as? [[String: Any]] else { return [] }
        var found: [(UInt32, CGRect)] = []
        for info in infos {
            guard (info["kCGWindowOwnerPID"] as? NSNumber)?.int32Value == pid else { continue }
            guard let number = (info["kCGWindowNumber"] as? NSNumber)?.uint32Value, number > 0 else { continue }
            guard let bounds = cgBounds(info["kCGWindowBounds"]) else { continue }
            found.append((number, bounds))
        }
        return found
    }

    private static func cgBounds(_ value: Any?) -> CGRect? {
        guard let dict = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? {
            (dict[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        guard let x = number("X"), let y = number("Y"), let width = number("Width"), let height = number("Height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func appKitFrame(fromAX rect: CGRect) -> NSRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let top = primary?.frame.maxY ?? rect.maxY
        return NSRect(x: rect.origin.x, y: top - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }

    private static func syntheticMenu(titles: [String], selected: String, appearance: NSAppearance) -> NSImage {
        let width: CGFloat = 180
        let row: CGFloat = 22
        let height = row * CGFloat(max(titles.count, 1)) + 10
        let image = NSImage(size: NSSize(width: width, height: height))
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            let card = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1), xRadius: 8, yRadius: 8)
            NSColor.windowBackgroundColor.setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
            card.stroke()
            let font = NSFont.menuFont(ofSize: 13)
            for (index, title) in titles.enumerated() {
                let y = height - 6 - row * CGFloat(index + 1)
                let rowRect = NSRect(x: 5, y: y, width: width - 10, height: row - 2)
                if title == selected {
                    NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
                    NSBezierPath(roundedRect: rowRect, xRadius: 4, yRadius: 4).fill()
                }
                let text = NSAttributedString(string: title, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ])
                text.draw(at: NSPoint(x: 28, y: y + 3))
                if title == selected {
                    let check = NSAttributedString(string: "✓", attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ])
                    check.draw(at: NSPoint(x: 10, y: y + 3))
                }
            }
            image.unlockFocus()
        }
        return image
    }

    private static func raster(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func cgWindowImage(_ windowNumber: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard windowNumber > 0,
              let symbol = dlsym(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY), "CGWindowListCreateImage") else {
            return nil
        }
        let create = unsafeBitCast(symbol, to: Create.self)
        let includingWindow: UInt32 = 1 << 3
        let options: UInt32 = (1 << 0) | (1 << 3)
        return create(.null, includingWindow, UInt32(windowNumber), options)?.takeRetainedValue()
    }

    private static func screenFrame(of view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private static func composite(_ shots: [(NSImage, NSRect)]) -> NSImage? {
        guard var union = shots.first?.1 else { return nil }
        for shot in shots.dropFirst() {
            union = union.union(shot.1)
        }
        let canvas = NSImage(size: union.size)
        canvas.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: union.size).fill()
        for (image, frame) in shots {
            let origin = NSPoint(x: frame.minX - union.minX, y: frame.minY - union.minY)
            image.draw(in: NSRect(origin: origin, size: frame.size), from: .zero, operation: .sourceOver, fraction: 1)
        }
        canvas.unlockFocus()
        return canvas
    }

    private static func writePNG(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static var model: BrowserModel? { attachedModel }
}

/// Retains itself until the common-mode timer fires during menu tracking.
nonisolated private final class PopupShot: NSObject, @unchecked Sendable {
    let path: String

    init(path: String) {
        self.path = path
    }

    func fire() {
        let path = self.path
        let work = {
            MainActor.assumeIsolated {
                DebugSnapshot.writeOpenPopup(to: path)
                DebugSnapshot.dismissPopup()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}

/// One resume across the page call and its deadline. Notification delivery is not the main actor.
private nonisolated final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

@MainActor
private final class SnapshotImageBox {
    var image: NSImage?
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

/// Which debug builds should act on a distributed notification.
nonisolated enum DebugNoteRouting {
    /// A process that set a private channel only accepts notes for that channel.
    /// A process with no channel only accepts notes that name no channel.
    static func accepts(noteChannel: String?, processChannels: [String]) -> Bool {
        let mine = processChannels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let trimmed = noteChannel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressed = (trimmed?.isEmpty == false) ? trimmed : nil
        if mine.isEmpty { return addressed == nil }
        guard let addressed else { return false }
        return mine.contains(addressed)
    }
}
