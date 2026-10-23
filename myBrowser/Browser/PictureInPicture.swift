import AppKit
import WebKit

/// Automatic Picture in Picture. The key is absent until the user changes Settings, and then it is on.
enum PictureInPictureSettings {
    static let autoDefaultsKey = "autoPictureInPicture"

    static var autoEnabled: Bool {
        guard UserDefaults.standard.object(forKey: autoDefaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: autoDefaultsKey)
    }
}

enum PictureInPictureOrigin: Equatable, Sendable {
    /// Toolbar, menu, shortcut, or the video's own control.
    case manual
    /// Selection moved off a playing tab.
    case leftTab
    /// The browser window lost key focus.
    case leftWindow
}

struct PictureInPictureSession: Equatable, Sendable {
    var tabID: UUID
    var origin: PictureInPictureOrigin
}

enum PictureInPictureEffect: Equatable, Sendable {
    case enter(UUID, PictureInPictureOrigin)
    case exit(UUID)
    /// Panel close. Pause inline. Do not select the tab or activate the window.
    case pause(UUID)
    /// Panel return-to-page. Select the tab and bring the window forward.
    case focus(UUID)
}

/// Why Picture in Picture left the system panel.
enum PictureInPictureDismissal: Equatable, Sendable {
    /// Toolbar, shortcut, or coming back to the tab. Playback continues inline.
    case requested
    /// The panel's close button.
    case stop
    /// The panel's return-to-page button.
    case restore
}

/// After the user closes the panel, auto-enter stays off until that video has paused and plays again.
struct PictureInPictureAutoBlock: Equatable, Sendable {
    var tabID: UUID
    var sawIdle: Bool
    /// A playback report in this window is still the one the user just closed.
    var holdUntil: Date
}

/// Decides when a playing tab enters or leaves system Picture in Picture.
/// WebKit calls stay outside this type so the rules can be tested without a web view.
enum PictureInPicturePolicy {
    static func selection(
        autoEnabled: Bool,
        session: PictureInPictureSession?,
        from: UUID?,
        fromCanEnter: Bool,
        to: UUID?
    ) -> (PictureInPictureSession?, [PictureInPictureEffect]) {
        if from == to { return (session, []) }

        if let session, session.tabID == to {
            return (nil, [.exit(session.tabID)])
        }

        if autoEnabled, session == nil, let from, fromCanEnter {
            return (PictureInPictureSession(tabID: from, origin: .leftTab), [.enter(from, .leftTab)])
        }

        return (session, [])
    }

    static func focus(
        autoEnabled: Bool,
        session: PictureInPictureSession?,
        windowFocused: Bool,
        selectedTab: UUID?,
        selectedCanEnter: Bool
    ) -> (PictureInPictureSession?, [PictureInPictureEffect]) {
        if windowFocused {
            if let session, session.origin == .leftWindow, session.tabID == selectedTab {
                return (nil, [.exit(session.tabID)])
            }
            return (session, [])
        }

        if session != nil { return (session, []) }
        guard autoEnabled, let selectedTab, selectedCanEnter else { return (session, []) }
        return (PictureInPictureSession(tabID: selectedTab, origin: .leftWindow), [.enter(selectedTab, .leftWindow)])
    }

    static func toggle(
        session: PictureInPictureSession?,
        tabID: UUID,
        isActive: Bool
    ) -> (PictureInPictureSession?, [PictureInPictureEffect]) {
        if isActive {
            return (nil, [.exit(tabID)])
        }
        var effects: [PictureInPictureEffect] = []
        if let session, session.tabID != tabID {
            effects.append(.exit(session.tabID))
        }
        effects.append(.enter(tabID, .manual))
        return (PictureInPictureSession(tabID: tabID, origin: .manual), effects)
    }

    /// The page entered Picture in Picture on its own (the video's control, or our enter call landing).
    static func pageEntered(
        session: PictureInPictureSession?,
        tabID: UUID
    ) -> PictureInPictureSession {
        if let session, session.tabID == tabID { return session }
        return PictureInPictureSession(tabID: tabID, origin: session?.origin ?? .manual)
    }

    /// The panel's return control. Focus now; the session ends when the mode actually drops.
    static func restore(
        session: PictureInPictureSession?,
        tabID: UUID
    ) -> (PictureInPictureSession?, [PictureInPictureEffect]) {
        guard session == nil || session?.tabID == tabID else { return (session, []) }
        return (session, [.focus(tabID)])
    }

    static func ended(
        session: PictureInPictureSession?,
        tabID: UUID,
        dismissal: PictureInPictureDismissal
    ) -> (PictureInPictureSession?, [PictureInPictureEffect]) {
        guard session?.tabID == tabID else { return (session, []) }
        switch dismissal {
        case .requested:
            return (nil, [])
        case .stop:
            return (nil, [.pause(tabID)])
        case .restore:
            return (nil, [.focus(tabID)])
        }
    }

    static func userStopBlock(tabID: UUID, now: Date = Date()) -> PictureInPictureAutoBlock {
        PictureInPictureAutoBlock(tabID: tabID, sawIdle: false, holdUntil: now.addingTimeInterval(2))
    }

    /// `canEnter` is the tab's raw eligibility, including a video that is still playing in the same breath as the close.
    /// While `sawIdle` is false that playback must not open the panel again. A later pause, then a new play, may.
    /// `holdUntil` also rejects that new play, so a report already in flight cannot reopen the panel.
    static func autoEnter(
        block: PictureInPictureAutoBlock?,
        tabID: UUID?,
        canEnter: Bool,
        isActive: Bool,
        now: Date = Date()
    ) -> (allowed: Bool, block: PictureInPictureAutoBlock?) {
        guard let tabID, var block, block.tabID == tabID else {
            return (canEnter, block)
        }
        if !isActive, !canEnter {
            block.sawIdle = true
        }
        if isActive || !canEnter || !block.sawIdle || now < block.holdUntil {
            return (false, block)
        }
        return (true, nil)
    }
}

/// WebKit's macOS Picture in Picture switch. The public configuration property is iOS-only,
/// the preference defaults to off, and `_togglePictureInPicture` does nothing without a Touch Bar.
enum PictureInPictureWebKit {
    private static let enableSelector = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
    private static let evaluateSelector = NSSelectorFromString(
        "_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:"
    )

    static func enable(_ preferences: WKPreferences) {
        guard preferences.responds(to: enableSelector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        let setter = unsafeBitCast(preferences.method(for: enableSelector), to: Setter.self)
        setter(preferences, enableSelector, true)
    }

    /// Runs `script` as a user gesture so `webkitSetPresentationMode` opens the system PiP panel.
    /// Public `evaluateJavaScript` leaves the activation bit clear, and WebKit then accepts the mode
    /// change without creating the panel.
    static func evaluate(
        _ webView: WKWebView,
        frame: WKFrameInfo?,
        script: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard webView.responds(to: evaluateSelector) else {
            webView.evaluateJavaScript(script, in: frame, in: .page) { result in
                let text: String?
                if case .success(let value) = result {
                    text = value as? String
                } else {
                    text = nil
                }
                Task { @MainActor in completion(text) }
            }
            return
        }

        typealias Eval = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            NSURL?,
            AnyObject?,
            WKContentWorld,
            Bool,
            @convention(block) (Any?, NSError?) -> Void
        ) -> Void
        let function = unsafeBitCast(webView.method(for: evaluateSelector), to: Eval.self)
        let block: @convention(block) (Any?, NSError?) -> Void = { result, _ in
            let text = result as? String
            Task { @MainActor in completion(text) }
        }
        function(webView, evaluateSelector, script as NSString, nil, frame, WKContentWorld.page, true, block)
    }
}

enum PictureInPictureScript {
    static let handlerName = "mybrowserPictureInPicture"
    static let marker = "__myBrowserPiP"
    /// Intrinsic pixels. Smaller videos (pixels, ad bugs) do not offer PiP.
    static let minimumArea = 160.0 * 90.0

    static let source = """
    (function () {
      if (window.__myBrowserPiP) return;
      var HANDLER = "\(handlerName)";
      var MIN_AREA = \(Int(minimumArea));
      var seen = [];

      function remember(video) {
        if (!video || video.tagName !== "VIDEO") return;
        for (var i = 0; i < seen.length; i++) if (seen[i] === video) return;
        seen.push(video);
        if (seen.length > 24) seen.shift();
      }

      function walk(node, out, depth, budget) {
        if (!node || depth > 8 || budget.n > 4000 || out.length > 24) return;
        budget.n++;
        if (node.tagName === "VIDEO") out.push(node);
        if (node.shadowRoot) walk(node.shadowRoot, out, depth + 1, budget);
        var child = node.firstElementChild;
        while (child && budget.n <= 4000 && out.length < 24) {
          walk(child, out, depth, budget);
          child = child.nextElementSibling;
        }
      }

      function videos() {
        var out = [];
        if (document.querySelectorAll) {
          var light = document.querySelectorAll("video");
          for (var i = 0; i < light.length; i++) out.push(light[i]);
        }
        for (var j = 0; j < seen.length; j++) {
          if (seen[j].isConnected) out.push(seen[j]);
        }
        if (document.documentElement) walk(document.documentElement, out, 0, { n: 0 });
        return out;
      }

      function areaOf(v) {
        var w = v.videoWidth || v.clientWidth || 0;
        var h = v.videoHeight || v.clientHeight || 0;
        return w * h;
      }

      function inPiP(v) {
        if (document.pictureInPictureElement === v) return true;
        return v.webkitPresentationMode === "picture-in-picture";
      }

      function canPiP(v) {
        if (!v || v.disablePictureInPicture) return false;
        if (typeof v.webkitSupportsPresentationMode === "function") {
          return !!v.webkitSupportsPresentationMode("picture-in-picture");
        }
        return !!(document.pictureInPictureEnabled && v.requestPictureInPicture);
      }

      function isPlaying(v) {
        return !v.paused && !v.ended && v.readyState >= 2;
      }

      function best() {
        var list = videos();
        var pick = null;
        var bestArea = 0;
        for (var i = 0; i < list.length; i++) {
          var v = list[i];
          if (inPiP(v)) return v;
          if (!isPlaying(v) || !canPiP(v)) continue;
          var area = areaOf(v);
          if (area < MIN_AREA) continue;
          if (area >= bestArea) { bestArea = area; pick = v; }
        }
        return pick;
      }

      function snapshot() {
        var list = videos();
        var playing = false;
        var supported = false;
        var active = false;
        var area = 0;
        for (var i = 0; i < list.length; i++) {
          var v = list[i];
          var pip = inPiP(v);
          var size = areaOf(v);
          if (pip) active = true;
          if (size > area) area = size;
          var live = isPlaying(v) && size >= MIN_AREA;
          if (live) playing = true;
          if ((pip || live) && canPiP(v)) supported = true;
        }
        if (active) supported = true;
        return { playing: playing, supported: supported, active: active, area: area };
      }

      function post(force) {
        var s = snapshot();
        var key = (s.playing ? "1" : "0") + (s.supported ? "1" : "0") + (s.active ? "1" : "0");
        if (!force && key === post.last) return;
        post.last = key;
        try {
          window.webkit.messageHandlers[HANDLER].postMessage({
            playing: !!s.playing,
            supported: !!s.supported,
            active: !!s.active,
            area: s.area
          });
        } catch (e) {}
      }
      post.last = "";

      function largest() {
        var list = videos();
        var pick = null;
        var bestArea = 0;
        for (var i = 0; i < list.length; i++) {
          var v = list[i];
          if (!canPiP(v)) continue;
          var area = areaOf(v);
          if (area < MIN_AREA) continue;
          if (area >= bestArea) { bestArea = area; pick = v; }
        }
        return pick;
      }

      function enter() {
        var v = best() || largest();
        if (!v) return "none";
        // Hiding the app can pause the element before this call lands. Resume muted.
        if (v.paused) {
          try { v.play(); } catch (e) {}
        }
        try {
          if (typeof v.webkitSetPresentationMode === "function") {
            v.webkitSetPresentationMode("picture-in-picture");
            return v.webkitPresentationMode || "webkit";
          }
        } catch (e) {}
        if (typeof v.requestPictureInPicture === "function") {
          v.requestPictureInPicture().then(function () {}, function () {});
          return "request";
        }
        return "unsupported";
      }

      function exit() {
        var list = videos();
        for (var i = 0; i < list.length; i++) {
          var v = list[i];
          if (v.webkitPresentationMode === "picture-in-picture" && v.webkitSetPresentationMode) {
            try { v.webkitSetPresentationMode("inline"); } catch (e) {}
          }
        }
        if (document.pictureInPictureElement && document.exitPictureInPicture) {
          document.exitPictureInPicture().then(function () {}, function () {});
        }
        return "ok";
      }

      function pause() {
        var list = videos();
        var any = false;
        for (var i = 0; i < list.length; i++) {
          var v = list[i];
          if (!(inPiP(v) || (isPlaying(v) && canPiP(v) && areaOf(v) >= MIN_AREA))) continue;
          try { v.pause(); any = true; } catch (e) {}
        }
        return any ? "ok" : "none";
      }

      window.__myBrowserPiP = { enter: enter, exit: exit, pause: pause, report: function () { post(true); } };

      function watch() {
        if (!document.documentElement) return;
        var events = ["play", "pause", "ended", "emptied", "loadeddata", "enterpictureinpicture", "leavepictureinpicture", "webkitpresentationmodechanged"];
        for (var i = 0; i < events.length; i++) {
          document.addEventListener(events[i], function (event) {
            remember(event.target);
            post(false);
          }, true);
        }
        setInterval(function () { post(true); }, 1000);
        post(true);
      }

      if (document.documentElement) watch();
      else document.addEventListener("DOMContentLoaded", watch, { once: true });
    })();
    """
}

struct PictureInPictureFrame {
    var frame: WKFrameInfo
    var playing: Bool
    var supported: Bool
    var active: Bool
    var area: Double
}

final class PictureInPictureRelay: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        tab?.receivePictureInPicture(message)
    }
}

func browserWindowForPictureInPicture() -> NSWindow? {
    NSApp.windows.first { window in
        window.level == .normal && window.styleMask.contains(.titled) && viewContainsWebView(window.contentView)
    }
}

private func viewContainsWebView(_ view: NSView?) -> Bool {
    guard let view else { return false }
    if view is WKWebView { return true }
    return view.subviews.contains { viewContainsWebView($0) }
}
