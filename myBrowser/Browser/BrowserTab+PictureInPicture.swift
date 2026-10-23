import AppKit
import WebKit

extension BrowserTab {
    func installPictureInPictureScript(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source.contains(PictureInPictureScript.marker) }) {
            controller.addUserScript(WKUserScript(
                source: PictureInPictureScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        controller.removeScriptMessageHandler(forName: PictureInPictureScript.handlerName)
        let relay = PictureInPictureRelay()
        relay.tab = self
        pictureInPictureRelay = relay
        controller.add(relay, name: PictureInPictureScript.handlerName)
    }

    func tearDownPictureInPicture() {
        if isPictureInPictureActive {
            suppressPictureInPictureReturn = true
            webView?.closeAllMediaPresentations(completionHandler: nil)
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: PictureInPictureScript.handlerName)
        pictureInPictureRelay?.tab = nil
        pictureInPictureRelay = nil
        pictureInPictureFrames.removeAll()
        let wasShowing = showsPictureInPictureButton
        hasPictureInPictureVideo = false
        if isPictureInPictureActive {
            isPictureInPictureActive = false
        }
        if wasShowing {
            onPictureInPicture?(self)
        }
    }

    func resetPictureInPictureFrames() {
        pictureInPictureFrames.removeAll()
        publishPictureInPicture(playing: false, supported: false, active: isPictureInPictureActive)
    }

    func receivePictureInPicture(_ message: WKScriptMessage) {
        guard let fields = message.body as? [String: Any] else { return }
        let frame = message.frameInfo
        let state = PictureInPictureFrame(
            frame: frame,
            playing: Self.boolField(fields["playing"]),
            supported: Self.boolField(fields["supported"]),
            active: Self.boolField(fields["active"]),
            area: Self.doubleField(fields["area"])
        )
        let frameID = Self.pictureInPictureFrameKey(frame)
        pictureInPictureFrames[frameID] = state
        if pictureInPictureFrames.count > 12 {
            let extras = pictureInPictureFrames.keys.filter { $0 != frameID }
            for key in extras.prefix(pictureInPictureFrames.count - 12) {
                pictureInPictureFrames.removeValue(forKey: key)
            }
        }
        let frames = pictureInPictureFrames.values
        let active = frames.contains { $0.active }
        let playing = frames.contains { $0.playing && $0.supported && ($0.area >= PictureInPictureScript.minimumArea || $0.active) }
        publishPictureInPicture(playing: playing, supported: playing || active, active: active)
    }

    func enterPictureInPicture() {
        guard let webView else { return }
        ensurePictureInPictureWindow(webView)
        let script = "window.__myBrowserPiP ? window.__myBrowserPiP.enter() : 'missing'"
        PictureInPictureWebKit.evaluate(webView, frame: bestPictureInPictureFrame(), script: script) { _ in }
    }

    func exitPictureInPicture() {
        suppressPictureInPictureReturn = true
        guard let webView else { return }
        let script = "window.__myBrowserPiP ? window.__myBrowserPiP.exit() : 'missing'"
        var frames = pictureInPictureFrames.values.map(\.frame)
        if let best = bestPictureInPictureFrame(), !frames.contains(where: { $0 === best }) {
            frames.append(best)
        }
        if frames.isEmpty {
            PictureInPictureWebKit.evaluate(webView, frame: nil, script: script) { _ in }
        } else {
            for frame in frames {
                PictureInPictureWebKit.evaluate(webView, frame: frame, script: script) { _ in }
            }
        }
        if isPictureInPictureActive {
            webView.closeAllMediaPresentations { [weak self] in
                self?.publishPictureInPicture(playing: self?.hasPictureInPictureVideo == true, supported: true, active: false)
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.suppressPictureInPictureReturn = false
        }
    }

    func consumePictureInPictureReturnSuppression() -> Bool {
        let value = suppressPictureInPictureReturn
        if value { suppressPictureInPictureReturn = false }
        return value
    }

    private func publishPictureInPicture(playing: Bool, supported: Bool, active: Bool) {
        let showVideo = playing && supported
        let changed = hasPictureInPictureVideo != showVideo || isPictureInPictureActive != active
        hasPictureInPictureVideo = showVideo
        isPictureInPictureActive = active
        if showVideo {
            pictureInPictureEligibleUntil = Date().addingTimeInterval(4)
        }
        if changed {
            onPictureInPicture?(self)
        }
    }

    private func bestPictureInPictureFrame() -> WKFrameInfo? {
        let frames = pictureInPictureFrames.values
        if let active = frames.first(where: { $0.active }) { return active.frame }
        return frames
            .filter { $0.playing && $0.supported && $0.area >= PictureInPictureScript.minimumArea }
            .max { $0.area < $1.area }?
            .frame
    }

    /// PiP only starts while the web view is in a window. A background tab's view may already have been detached.
    private func ensurePictureInPictureWindow(_ webView: WKWebView) {
        guard webView.window == nil else { return }
        guard let host = pictureInPictureHost?() else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        if let first = host.subviews.first {
            host.addSubview(webView, positioned: .below, relativeTo: first)
        } else {
            host.addSubview(webView)
        }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// Stable across the new `WKFrameInfo` instance WebKit creates for each script message.
    private static func pictureInPictureFrameKey(_ frame: WKFrameInfo) -> String {
        if frame.isMainFrame { return "main" }
        let host = frame.securityOrigin.host
        let url = frame.request.url?.absoluteString ?? ""
        return "\(host)|\(url)"
    }

    private static func boolField(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func doubleField(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return 0
    }
}
