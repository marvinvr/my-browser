import AppKit
import Observation
import WebKit

/// One toolbar action. Rebuilt whenever the extension updates its icon, badge, or label.
struct ExtensionToolbarItem: Identifiable {
    var id: String
    var label: String
    var badge: String
    var isEnabled: Bool
    var image: NSImage?
}

/// App-level extension registry. One `WKWebExtensionController` per profile.
@Observable
final class ExtensionManager {
    let directory: URL
    let window = ExtensionWindow()

    private(set) var records: [ExtensionRecord] = []
    /// Bumped when an action's icon, badge, or label changes.
    private(set) var revision = 0
    private(set) var lastError: String?
    private(set) var isBusy = false

    @ObservationIgnored private let bridge = ExtensionControllerBridge()
    @ObservationIgnored let nativeMessaging = NativeMessagingCenter()
    @ObservationIgnored private var controllers: [UUID: WKWebExtensionController] = [:]
    @ObservationIgnored private var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
    @ObservationIgnored private var snapshots: [UUID: TabSnapshot] = [:]
    @ObservationIgnored private var openedTabs: Set<UUID> = []
    @ObservationIgnored private var announcedWindows: Set<UUID> = []
    @ObservationIgnored private var anchors: [String: AnchorBox] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var popupPanels: [ExtensionPopupPanel] = []
    /// Background pages WebKit has created. The public context API does not return the view.
    @ObservationIgnored private var backgroundWebViews: [ObjectIdentifier: WKWebView] = [:]
    /// Contexts whose content scripts are installed inside WebKit's storage-migration
    /// callback, after `load` has already returned. The reload waits for that callback.
    @ObservationIgnored private var pendingInjectionReload: Set<ObjectIdentifier> = []
    @ObservationIgnored private var promptTail: Task<Bool, Never>?
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored weak var model: BrowserModel?
    @ObservationIgnored let contentBlocker: ContentBlockerController

    init(directory: URL) {
        self.directory = directory
        contentBlocker = ContentBlockerController(extensionsDirectory: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            records = try ExtensionCatalogStore.load(from: directory)
        } catch {
            records = []
            lastError = "Couldn't read the extension list. The previous file was kept beside it."
        }
        contentBlocker.recordsProvider = { [weak self] in self?.records ?? [] }
    }

    /// Call after this object is retained. A weak delegate pointer set inside `init` does not stick.
    func connectOwner() {
        bridge.manager = self
    }

    /// Binds the window model and loads extensions that are enabled for a profile.
    func attach(_ model: BrowserModel) {
        connectOwner()
        self.model = model
        window.model = model
        contentBlocker.attach(model)
        observeFocus()
    }

    /// Loads enabled extensions after the first frame. Doing it from `init` runs during
    /// SwiftUI's launch notification and trips a main-actor assertion when a large
    /// extension (1Password) is already installed.
    func loadEnabledExtensions() async {
        contentBlocker.refresh()
        await loadEnabled()
        #if DEBUG
        debugLoadNote(debugLoadReport())
        #endif
        // A second bump after the await. SwiftUI can miss the mutation that lands
        // inside the load continuation, so the toolbar stays empty.
        revision &+= 1
    }

    #if DEBUG
    private func debugLoadNote(_ text: String) {
        guard let library = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"], !library.isEmpty else { return }
        try? text.write(
            to: URL(fileURLWithPath: library, isDirectory: true).appendingPathComponent("ext-load.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func debugLoadReport() -> String {
        var lines = [
            "selected=\(model?.selectedSpace?.profileID.uuidString ?? "nil")",
            "records=\(records.count)",
            "contexts=\(contexts.values.reduce(0) { $0 + $1.count })",
            "error=\(lastError ?? "")"
        ]
        for record in records {
            lines.append("record \(record.id) enabled=\(record.enabledProfileIDs.map(\.uuidString).joined(separator: ","))")
        }
        for (profileID, map) in contexts {
            for (id, context) in map {
                let errs = context.errors.prefix(3).map(\.localizedDescription).joined(separator: " | ")
                lines.append("ctx \(profileID.uuidString) \(id) loaded=\(context.isLoaded) inject=\(context.hasInjectedContent) allHosts=\(context.hasAccessToAllHosts) action=\(context.action(for: nil) != nil) base=\(context.baseURL.absoluteString) errs=\(errs)")
            }
        }
        if let tab = model?.selectedTab {
            let attached = tab.webView?.configuration.webExtensionController != nil
            lines.append("tab \(tab.profileID.uuidString) webExt=\(attached) host=\(tab.url?.host ?? "")")
        }
        return lines.joined(separator: "\n")
    }
    #endif

    func save() {
        do {
            try ExtensionCatalogStore.save(records, to: directory)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The profile's controller, created on first use so web views can reference it before any extension is loaded.
    func controller(for profileID: UUID) -> WKWebExtensionController {
        if let existing = controllers[profileID] { return existing }
        let configuration = WKWebExtensionController.Configuration(identifier: profileID)
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        configuration.defaultWebsiteDataStore = store
        configuration.webViewConfiguration.websiteDataStore = store
        configuration.webViewConfiguration.applicationNameForUserAgent = ProfileManager.safariApplicationName
        WebInspector.enableDeveloperExtras(configuration.webViewConfiguration.preferences)
        PageRenderingRate.apply(to: configuration.webViewConfiguration.preferences)
        // Extension pages only. The script fills out the notifications stub before
        // the page's own scripts. The service worker is checked separately.
        configuration.webViewConfiguration.userContentController.addUserScript(Self.notificationsShimScript)
        let controller = WKWebExtensionController(configuration: configuration)
        // Release WebKit hides `chrome.notifications` unless the controller is in
        // testing mode. What it exposes there is a partial stub: `onClicked` exists,
        // `onClosed` does not. 1Password's service worker reads both while the module
        // is still evaluating. This SDK has no `WebExtensionNotificationsEnabled`
        // preference. `_setTestingMode:` is the switch WebKit uses.
        if controller.responds(to: Selector(("_setTestingMode:"))) {
            controller.setValue(true, forKey: "testingMode")
        }
        controller.delegate = bridge
        controllers[profileID] = controller
        return controller
    }

    func toolbarItems(profileID: UUID, tab: BrowserTab?) -> [ExtensionToolbarItem] {
        _ = revision
        _ = tab
        guard let loaded = contexts[profileID] else { return [] }
        return records.compactMap { record in
            guard loaded[record.id] != nil else { return nil }
            // The manifest icon. Reading `WKWebExtension.Action` here walks the tab and,
            // for 1Password, drops the whole SwiftUI toolbar update.
            return ExtensionToolbarItem(
                id: record.id,
                label: record.name,
                badge: "",
                isEnabled: true,
                image: iconCache[record.id] ?? icon(for: record)
            )
        }
    }

    func registerAnchor(_ view: NSView, for extensionID: String) {
        let box = anchors[extensionID] ?? AnchorBox()
        box.view = view
        anchors[extensionID] = box
    }

    func performAction(extensionID: String, profileID: UUID, tab: BrowserTab?) {
        contexts[profileID]?[extensionID]?.performAction(for: tab)
    }

    /// `windows.create({type:"popup"})` for an extension page. 1Password opens its detached popup this way.
    func presentDetachedPopup(url: URL, configuration: WKWebViewConfiguration, frame: CGRect) -> ExtensionPopupPanel {
        let panel = ExtensionPopupPanel(url: url, configuration: configuration, requestedFrame: frame)
        popupPanels.append(panel)
        panel.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            self?.popupPanels.removeAll { $0 === panel }
        }
        return panel
    }

    func presentPopup(for action: WKWebExtension.Action) {
        guard action.presentsPopup, let popover = action.popupPopover else { return }
        popover.behavior = .transient
        let identifier = action.webExtensionContext?.uniqueIdentifier
        if let identifier, let anchor = anchors[identifier]?.view, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            self.schedulePopupTag(popover)
            fitPopup(popover, action: action)
            return
        }
        guard let content = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        let rect = NSRect(x: content.bounds.midX - 1, y: content.isFlipped ? 40 : content.bounds.height - 40, width: 2, height: 2)
        popover.show(relativeTo: rect, of: content, preferredEdge: .minY)
        schedulePopupTag(popover)
        fitPopup(popover, action: action)
    }

    func performExtensionCommand(for event: NSEvent) -> Bool {
        guard !event.isARepeat else { return false }
        guard let profileID = model?.selectedSpace?.profileID, let loaded = contexts[profileID] else { return false }
        for context in loaded.values where context.performCommand(for: event) {
            return true
        }
        return false
    }

    func stopNativeHosts() {
        nativeMessaging.stopAll()
    }

    /// WebKit sizes the popover from the popup document. A page that lays out after load
    /// (the 1Password popup does) otherwise stays at the empty size.
    private func fitPopup(_ popover: NSPopover, action: WKWebExtension.Action) {
        let delays: [Duration] = [.milliseconds(50), .milliseconds(250), .milliseconds(700)]
        for delay in delays {
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard popover.isShown, let webView = action.popupWebView else { return }
                let script = """
                (() => {
                  const doc = document.documentElement;
                  const body = document.body;
                  const w = Math.max(doc ? doc.scrollWidth : 0, body ? body.scrollWidth : 0, doc ? doc.offsetWidth : 0);
                  const h = Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0, doc ? doc.offsetHeight : 0);
                  const root = document.getElementById("root");
                  const text = body ? (body.innerText || "") : "";
                  const words = ["Unlock", "Locked", "Sign in", "1Password", "Loading", "Error", "Integrate"].filter((word) => text.includes(word));
                  const errs = (globalThis.__mbPageErrors || []).slice(0, 4);
                  return {w: Math.ceil(w), h: Math.ceil(h), kids: root ? root.childElementCount : -1, textLen: text.length, title: document.title || "", ready: document.readyState, words, errs};
                })()
                """
                let result = try? await webView.evaluateJavaScript(script)
                if let library = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"], !library.isEmpty {
                    Self.appendDebugNote(directory: library, name: "popup-structure.txt", line: "\(delay): \(String(describing: result ?? "nil"))\n")
                }
                guard let size = Self.popupSize(from: result) else { return }
                let current = popover.contentSize
                if abs(current.width - size.width) > 8 || abs(current.height - size.height) > 8 {
                    popover.contentSize = size
                }
            }
        }
    }

    /// WebKit's testing-mode `chrome.notifications` has `onClicked` and not `onClosed`.
    /// `webNavigation` is missing `onCreatedNavigationTarget`. `storage.managed` is absent.
    /// 1Password reads all three while starting. A property set once at evaluation is gone
    /// by the time that async init runs, so the fill is repeated for a few seconds.
    private static let notificationsShimMarker = "/* mb-notifications-shim */"
    private static let notificationsShimVersion = "/* mb-shim-wasm-status */"

    private static let notificationsShimSource = """
    /* mb-notifications-shim */
    /* mb-shim-native-port */
    /* mb-shim-privacy */
    /* mb-shim-wasm-mime */
    /* mb-shim-wasm-status */
    (() => {
      // WebKit serves .wasm as application/octet-stream. instantiateStreaming
      // then reads the body and rejects, and the caller's arrayBuffer fallback
      // fails because the body is already used. 1Password's core never starts.
      try {
        const nativeStreaming = WebAssembly.instantiateStreaming;
        if (typeof nativeStreaming === "function") {
          const note = (value) => { try { globalThis.__mbWasmLoad = value; } catch (e) {} };
          WebAssembly.instantiateStreaming = function(source, imports) {
            const response = source instanceof Response ? source : null;
            const type = response && response.headers ? (response.headers.get("content-type") || "") : "";
            if (response && response.ok && type !== "application/wasm") {
              note("fallback");
              return response.arrayBuffer().then((buf) => WebAssembly.instantiate(buf, imports)).then((out) => {
                note("ok");
                return out;
              }, (error) => {
                note("fail " + ((error && error.name) || "error"));
                throw error;
              });
            }
            note("native");
            return nativeStreaming.call(WebAssembly, source, imports);
          };
        }
      } catch (e) {}
      const event = () => ({
        addListener() {},
        removeListener() {},
        hasListener() { return false; },
        hasListeners() { return false; }
      });
      const fillEvents = (api, names) => {
        if (!api || typeof api !== "object") return;
        for (const name of names) {
          if (!api[name]) { try { api[name] = event(); } catch (e) {} }
        }
      };
      const fillNotifications = (api) => {
        fillEvents(api, ["onClicked", "onButtonClicked", "onClosed", "onShown"]);
        if (!api || typeof api !== "object") return;
        const ok = (value) => () => Promise.resolve(value);
        if (typeof api.create !== "function") { try { api.create = ok(""); } catch (e) {} }
        if (typeof api.update !== "function") { try { api.update = ok(false); } catch (e) {} }
        if (typeof api.clear !== "function") { try { api.clear = ok(true); } catch (e) {} }
        if (typeof api.getAll !== "function") { try { api.getAll = ok([]); } catch (e) {} }
        if (typeof api.getPermissionLevel !== "function") { try { api.getPermissionLevel = ok("granted"); } catch (e) {} }
      };
      const managedArea = () => ({
        get(keys, callback) {
          const value = {};
          if (typeof keys === "function") { keys(value); return; }
          if (typeof callback === "function") { callback(value); return; }
          return Promise.resolve(value);
        },
        set(_items, callback) {
          if (typeof _items === "function") { _items(); return; }
          if (typeof callback === "function") { callback(); return; }
          return Promise.resolve();
        },
        remove(_keys, callback) {
          if (typeof _keys === "function") { _keys(); return; }
          if (typeof callback === "function") { callback(); return; }
          return Promise.resolve();
        },
        clear(callback) {
          if (typeof callback === "function") { callback(); return; }
          return Promise.resolve();
        },
        onChanged: event()
      });
      const fillStorage = (storage) => {
        if (!storage || typeof storage !== "object") return;
        if (!storage.managed) {
          try { storage.managed = managedArea(); } catch (e) {}
        } else if (!storage.managed.onChanged) {
          try { storage.managed.onChanged = event(); } catch (e) {}
        }
      };
      const fillPrivacy = (namespace) => {
        if (!namespace) return;
        let privacy = null;
        try { privacy = namespace.privacy; } catch (e) { privacy = null; }
        if (privacy && privacy.services && privacy.services.passwordSavingEnabled) return;
        const setting = () => ({
          get(details, cb) {
            const result = { value: false, levelOfControl: "not_controllable" };
            if (typeof cb === "function") cb(result);
            return Promise.resolve(result);
          },
          set(details, cb) { if (typeof cb === "function") cb(); return Promise.resolve(); },
          clear(details, cb) { if (typeof cb === "function") cb(); return Promise.resolve(); }
        });
        const category = new Proxy({}, { get: () => setting() });
        try { namespace.privacy = { services: category, network: category, websites: category }; } catch (e) {}
      };
      const fillNamespace = (namespace) => {
        if (!namespace) return;
        fillNotifications(namespace.notifications);
        fillStorage(namespace.storage);
        fillPrivacy(namespace);
        fillEvents(namespace.webNavigation, [
          "onCreatedNavigationTarget",
          "onHistoryStateUpdated",
          "onReferenceFragmentUpdated",
          "onTabReplaced"
        ]);
      };
      // connectNative returns a port before WebKit has connected the native side.
      // A postMessage in that same turn is queued, and when the port connects WebKit
      // sends the queue back to the extension instead of to the native host.
      const deferNativePort = (runtime) => {
        if (!runtime || typeof runtime.connectNative !== "function") return;
        if (runtime.connectNative.__mbDeferred) return;
        const connect = runtime.connectNative.bind(runtime);
        const wrapped = function (name) {
          const port = connect(name);
          if (!port || typeof port.postMessage !== "function" || port.postMessage.__mbDeferred) return port;
          const post = port.postMessage.bind(port);
          const queued = [];
          let open = false;
          const flush = () => {
            if (open) return;
            open = true;
            const pending = queued.splice(0);
            for (const message of pending) {
              try { post(message); } catch (e) {}
            }
          };
          const deferred = function (message) {
            if (open) return post(message);
            queued.push(message);
          };
          deferred.__mbDeferred = true;
          try {
            Object.defineProperty(port, "postMessage", { configurable: true, writable: true, value: deferred });
          } catch (e) {
            try { port.postMessage = deferred; } catch (e2) {}
          }
          setTimeout(flush, 50);
          return port;
        };
        wrapped.__mbDeferred = true;
        try {
          Object.defineProperty(runtime, "connectNative", { configurable: true, writable: true, value: wrapped });
        } catch (e) {
          try { runtime.connectNative = wrapped; } catch (e2) {}
        }
      };
      const fill = () => {
        try {
          fillNamespace(globalThis.chrome);
          if (globalThis.browser && globalThis.browser !== globalThis.chrome) fillNamespace(globalThis.browser);
          deferNativePort(globalThis.chrome && globalThis.chrome.runtime);
          if (globalThis.browser && globalThis.browser !== globalThis.chrome) deferNativePort(globalThis.browser.runtime);
        } catch (e) {}
      };
      fill();
      let ticks = 0;
      const timer = setInterval(() => {
        ticks += 1;
        fill();
        if (ticks >= 480) clearInterval(timer);
      }, 25);
      const errors = [];
      try { globalThis.__mbPageErrors = errors; } catch (e) {}
      try {
        addEventListener("error", (event) => {
          errors.push(String(event.message || (event.error && event.error.message) || "error").slice(0, 180));
        });
        addEventListener("unhandledrejection", (event) => {
          const reason = event.reason;
          errors.push(String((reason && (reason.message || reason)) || "rejection").slice(0, 180));
        });
        const report = console.error.bind(console);
        console.error = (...args) => {
          try {
            errors.push(args.map((arg) => String((arg && arg.message) || arg)).join(" ").slice(0, 180));
          } catch (e) {}
          return report(...args);
        };
      } catch (e) {}
    })();

    """

    /// Runs in extension pages (popup, options). The service worker does not run user scripts,
    /// so `installServiceWorkerNotificationsShim` writes the same prelude into that file.
    private static let notificationsShimScript = WKUserScript(
        source: notificationsShimSource,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// Prepends the compatibility prelude to an MV3 service worker that asks for notifications
    /// or webNavigation. Static `import` stays legal: a statement may precede import declarations.
    /// The prelude runs before the rest of that module's body.
    static func installServiceWorkerNotificationsShim(in folder: URL) {
        let manifestURL = folder.appending(path: "manifest.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = json["permissions"] as? [String],
              permissions.contains("notifications") || permissions.contains("webNavigation"),
              let background = json["background"] as? [String: Any],
              let worker = background["service_worker"] as? String,
              !worker.isEmpty,
              !worker.hasPrefix("/"),
              !worker.contains("..") else { return }
        let file = folder.appending(path: worker, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        guard var body = try? String(contentsOf: file, encoding: .utf8) else { return }
        if body.hasPrefix(notificationsShimMarker) {
            let head = body.prefix(8000)
            if head.contains(notificationsShimVersion) { return }
            // The prelude is one IIFE. Its close is the only column-0 `})();`.
            // A blank line after it is not guaranteed, so don't require one.
            guard let end = body.range(of: "\n})();\n") else { return }
            body = String(body[end.upperBound...])
        }
        body = notificationsShimSource + body
        try? body.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func appendDebugNote(directory: String, name: String, line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try? FileHandle(forWritingTo: url)
            try? handle?.seekToEnd()
            try? handle?.write(data)
            try? handle?.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Opt-in notes when `MYBROWSER_DEBUG_LIBRARY` is set. Counts and error strings only.
    /// No page text and no native-message bodies.
    private func noteOnePasswordHealth(context: WKWebExtensionContext, id: String) {
        guard id == OnePasswordPackage.extensionID,
              let library = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"],
              !library.isEmpty else { return }
        let tab = model?.selectedTab
        let url = tab?.url
        let access = url.map { context.hasAccess(to: $0, in: tab) } ?? false
        let injects = url.map { context.hasInjectedContent(for: $0) } ?? false
        let attached = tab?.webView?.configuration.webExtensionController != nil
        let loaded = "loaded inject=\(context.hasInjectedContent) allHosts=\(context.hasAccessToAllHosts) allURLs=\(context.hasAccessToAllURLs) urlAccess=\(access) injectsURL=\(injects) webExt=\(attached) scheme=\(url?.scheme ?? "") host=\(url?.host ?? "") \(injectionSummary(context: context))\n"
        Self.appendDebugNote(directory: library, name: "op-health.txt", line: loaded)
        // Toolbar click only for an explicit throwaway probe. DEBUG_LIBRARY alone must
        // not steal the selected tab (snapshot runs set that variable).
        if ProcessInfo.processInfo.environment["MYBROWSER_OP_PROBE"] == "1",
           let profileID = model?.selectedSpace?.profileID {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(9))
                self.performAction(extensionID: id, profileID: profileID, tab: self.model?.selectedTab)
            }
        }
        let delays: [Duration] = [.seconds(2), .seconds(6), .seconds(12), .seconds(18)]
        for delay in delays {
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                Self.appendDebugNote(directory: library, name: "op-health.txt", line: "inject \(delay): \(self.injectionSummary(context: context))\n")
                if let webView = self.backgroundWebView(for: context) {
                    let script = """
                    (() => {
                      const privacy = !!(globalThis.chrome && chrome.privacy && chrome.privacy.services);
                      const host = String(location.href || "").split("/")[2] || "";
                      const hasWasm = typeof WebAssembly !== "undefined" && typeof WebAssembly.compile === "function";
                      if (!globalThis.__mbWasmProbe) {
                        globalThis.__mbWasmProbe = "start has=" + hasWasm;
                        fetch("/assets/wasm/op-core-b5x_bg-6QVPXTHW.wasm").then(async (res) => {
                          const ct = res.headers.get("content-type") || "";
                          let note = "status=" + res.status + " type=" + res.type + " ct=" + ct.slice(0, 40);
                          if (res.ok && hasWasm) {
                            const buf = await res.arrayBuffer();
                            note += " bytes=" + buf.byteLength;
                            try {
                              await WebAssembly.compile(buf);
                              note += " compile=ok";
                            } catch (e) {
                              note += " compile=" + ((e && e.name) || "error");
                            }
                          }
                          globalThis.__mbWasmProbe = note;
                        }).catch((e) => {
                          let msg = String((e && e.message) || "").slice(0, 90);
                          msg = msg.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, "");
                          globalThis.__mbWasmProbe = "err=" + ((e && e.name) || "error") + " " + msg;
                        });
                      }
                      const errs = (globalThis.__mbPageErrors || []).slice(0, 3).join(" | ").replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/g, "");
                      return "host=" + host + " privacy=" + (privacy ? 1 : 0) + " wasm=" + globalThis.__mbWasmProbe + " load=" + (globalThis.__mbWasmLoad || "") + " errs=" + errs.slice(0, 220);
                    })()
                    """
                    do {
                        let result = try await webView.evaluateJavaScript(script)
                        Self.appendDebugNote(directory: library, name: "op-health.txt", line: "worker \(delay): \(String(describing: result ?? "nil"))\n")
                    } catch {
                        let note = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                        Self.appendDebugNote(directory: library, name: "op-health.txt", line: "worker \(delay) eval: \(note.prefix(180))\n")
                    }
                } else {
                    Self.appendDebugNote(directory: library, name: "op-health.txt", line: "worker \(delay): no background view\n")
                }
                if let webView = self.model?.selectedTab?.webView {
                    let probe = ProcessInfo.processInfo.environment["MYBROWSER_OP_PROBE"] == "1"
                    let script = """
                    (() => {
                      const probe = \(probe ? "true" : "false");
                      let marks = 0;
                      let shadows = 0;
                      for (const node of document.querySelectorAll("*")) {
                        if (node.shadowRoot) shadows += 1;
                        const id = node.id || "";
                        const cls = typeof node.className === "string" ? node.className : "";
                        if (/1password|com-1password/i.test(id + " " + cls)) marks += 1;
                      }
                      const title = document.title || "";
                      const safe = /^(mb-|1Password$)/.test(title) || title.length === 0 ? title : ("len:" + title.length);
                      const root = document.getElementById("root");
                      const allow = ["Unlock", "unlock", "Locked", "Sign in", "Welcome", "Loading", "Error", "Integrate", "Touch", "Open", "Connect", "Desktop", "Browser", "Get started", "Set up", "Approve", "Enable", "Continue", "ready", "Please", "account"];
                      const text = (document.body && document.body.innerText || "").slice(0, 4000);
                      const words = allow.filter((word) => text.includes(word));
                      const password = document.querySelector('input[type="password"]');
                      if (probe && password) { try { password.focus(); } catch (e) {} }
                      const buttons = document.querySelectorAll("button").length;
                      if (probe && !window.__mbCont) {
                        for (const button of document.querySelectorAll("button")) {
                          if ((button.innerText || "").trim() === "Continue") {
                            window.__mbCont = 1;
                            button.click();
                            break;
                          }
                        }
                      }
                      return {
                        title: safe,
                        inputs: document.querySelectorAll("input").length,
                        buttons,
                        textLen: text.length,
                        marks, shadows,
                        rootChildren: root ? root.childElementCount : -1,
                        words
                      };
                    })()
                    """
                    let result = try? await webView.evaluateJavaScript(script)
                    Self.appendDebugNote(directory: library, name: "op-health.txt", line: "page \(delay): \(String(describing: result ?? "nil"))\n")
                }
            }
        }
    }

    /// Counts only. Script source and page text stay out of the log.
    private func injectionSummary(context: WKWebExtensionContext) -> String {
        let base = context.baseURL.host ?? ""
        let errs = context.errors.prefix(3).map(\.localizedDescription).joined(separator: " | ")
        guard let webView = model?.selectedTab?.webView else {
            return "base=\(base) tab=none errs=\(errs)"
        }
        let scripts = webView.configuration.userContentController.userScripts
        let compat = scripts.reduce(into: 0) { count, script in
            if script.source.contains("__myBrowserCompat") { count += 1 }
        }
        let persistent = webView.configuration.websiteDataStore.isPersistent
        return "base=\(base) scripts=\(scripts.count) compat=\(compat) persistent=\(persistent) errs=\(errs)"
    }

    private static func popupSize(from result: Any?) -> NSSize? {
        let values: [String: Any]
        if let dictionary = result as? [String: Any] {
            values = dictionary
        } else if let dictionary = result as? NSDictionary {
            values = dictionary as? [String: Any] ?? [:]
        } else {
            return nil
        }
        guard let width = number(values["w"]), let height = number(values["h"]), width > 40, height > 40 else { return nil }
        return NSSize(width: min(max(width, 160), 480), height: min(max(height, 80), 680))
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        if let number = value as? Double { return CGFloat(number) }
        if let number = value as? Int { return CGFloat(number) }
        return nil
    }

    private func schedulePopupTag(_ popover: NSPopover) {
        tagPopup(popover)
        Task { @MainActor in
            self.tagPopup(popover)
        }
    }

    private func tagPopup(_ popover: NSPopover) {
        guard let window = popover.contentViewController?.view.window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("extension-popup")
        window.title = "Extension popup"
    }

    func icon(for record: ExtensionRecord) -> NSImage? {
        if let cached = iconCache[record.id] { return cached }
        let folder = directory.appending(path: record.directory, directoryHint: .isDirectory)
        guard let loaded = try? ExtensionManifest.load(from: folder),
              let relative = loaded.manifest.iconRelativePath else { return nil }
        let url = folder.appending(path: relative, directoryHint: .notDirectory).standardizedFileURL
        guard url.path(percentEncoded: false).hasPrefix(folder.standardizedFileURL.path(percentEncoded: false)),
              let image = NSImage(contentsOf: url) else { return nil }
        iconCache[record.id] = image
        return image
    }

    func clearError() { lastError = nil }

    // MARK: Install

    func install(from source: URL, kind: ExtensionSource? = nil, preferredID: String? = nil) async {
        let resolvedKind = kind ?? ExtensionPackage.sourceKind(for: source)
        await install(kind: resolvedKind, preferredID: preferredID) {
            try await ExtensionPackage.prepare(source: source, into: self.directory, sourceKind: resolvedKind, preferredID: preferredID)
        }
    }

    func installFromChromeWebStore(_ text: String) async {
        guard let id = ChromeWebStoreLink.extensionID(in: text) else {
            lastError = "Paste a Chrome Web Store link or a 32-character extension id."
            return
        }
        await install(kind: .chromeWebStore, preferredID: id) {
            let data = try await ChromeWebStoreLink.download(id: id)
            let file = FileManager.default.temporaryDirectory.appending(path: "\(id).crx", directoryHint: .notDirectory)
            try data.write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await ExtensionPackage.prepare(
                source: file,
                into: self.directory,
                sourceKind: .chromeWebStore,
                preferredID: id
            )
        }
    }

    func setEnabled(_ enabled: Bool, id: String, profileID: UUID) async {
        guard var record = records.first(where: { $0.id == id }) else { return }
        clearError()
        if enabled {
            if !record.enabledProfileIDs.contains(profileID) {
                record.enabledProfileIDs.append(profileID)
            }
            replace(record)
            do {
                try await load(record, profileID: profileID, reloadPages: true)
            } catch {
                var rolled = record
                rolled.enabledProfileIDs.removeAll { $0 == profileID }
                replace(rolled)
                lastError = error.localizedDescription
            }
        } else {
            unload(id: id, profileID: profileID)
            record.enabledProfileIDs.removeAll { $0 == profileID }
            replace(record)
            contentBlocker.refresh()
        }
    }

    func remove(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        for profileID in record.enabledProfileIDs {
            unload(id: id, profileID: profileID)
        }
        let folder = directory.appending(path: record.directory, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        iconCache[id] = nil
        records.removeAll { $0.id == id }
        save()
        contentBlocker.refresh()
    }

    /// Opens the options page with the extension's own web view configuration. Returns an error when there is nothing to open.
    @discardableResult
    func openOptionsPage(for context: WKWebExtensionContext) -> Error? {
        guard let model else { return ExtensionInstallError.webKit("No window is open.") }
        guard let url = context.optionsPageURL, let configuration = context.webViewConfiguration else {
            return ExtensionInstallError.webKit("This extension doesn't have an options page.")
        }
        guard model.presentPopup(configuration: configuration, url: url, spaceID: model.selectedSpaceID) != nil else {
            return ExtensionInstallError.webKit("Couldn't open the options page.")
        }
        return nil
    }

    func openOptions(id: String) {
        guard let profileID = model?.selectedSpace?.profileID, let context = contexts[profileID]?[id] else {
            lastError = "Enable the extension in this profile to open its options."
            return
        }
        if let error = openOptionsPage(for: context) {
            lastError = error.localizedDescription
        }
    }

    // MARK: Tab events

    func tabOpened(_ tab: BrowserTab) {
        guard openedTabs.insert(tab.id).inserted else { return }
        snapshots[tab.id] = snapshot(of: tab)
        let controller = controllers[tab.profileID] ?? controller(for: tab.profileID)
        announceWindow(profileID: tab.profileID, controller: controller)
        controller.didOpenTab(tab)
    }

    func tabClosed(_ tab: BrowserTab) {
        openedTabs.remove(tab.id)
        snapshots[tab.id] = nil
        guard let controller = controllers[tab.profileID] else { return }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        guard let controller = controllers[tab.profileID] else { return }
        controller.didActivateTab(tab, previousActiveTab: previous)
        revision &+= 1
    }

    func tabPropertiesChanged(_ tab: BrowserTab) {
        let next = snapshot(of: tab)
        let previous = snapshots[tab.id]
        snapshots[tab.id] = next
        guard let previous, let controller = controllers[tab.profileID] else { return }
        var properties: WKWebExtension.TabChangedProperties = []
        if previous.title != next.title { properties.insert(.title) }
        if previous.url != next.url { properties.insert(.URL) }
        if previous.isLoading != next.isLoading { properties.insert(.loading) }
        if previous.isPinned != next.isPinned { properties.insert(.pinned) }
        guard !properties.isEmpty else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func noteActionUpdated() {
        revision &+= 1
    }

    // MARK: Permissions

    func ask(_ request: PermissionPrompt.Request) async -> Bool {
        let previous = promptTail
        let next = Task { @MainActor in
            if let previous { _ = await previous.value }
            return await PermissionPrompt.confirm(request)
        }
        promptTail = next
        return await next.value
    }

    func remember(
        permissions: Set<WKWebExtension.Permission>,
        patterns: [String],
        granted: Bool,
        context: WKWebExtensionContext
    ) {
        guard let id = recordID(matching: context), var record = records.first(where: { $0.id == id }) else { return }
        let names = permissions.map(\.rawValue)
        if granted {
            record.grantedPermissions.append(contentsOf: names)
            record.deniedPermissions.removeAll { names.contains($0) }
            record.grantedMatchPatterns.append(contentsOf: patterns)
            record.deniedMatchPatterns.removeAll { patterns.contains($0) }
        } else {
            record.deniedPermissions.append(contentsOf: names)
            record.grantedPermissions.removeAll { names.contains($0) }
            record.deniedMatchPatterns.append(contentsOf: patterns)
            record.grantedMatchPatterns.removeAll { patterns.contains($0) }
        }
        replace(record)
    }

    // MARK: Private

    private func install(kind: ExtensionSource, preferredID: String?, prepare: () async throws -> ExtensionPackage.Prepared) async {
        clearError()
        isBusy = true
        defer { isBusy = false }
        if let preferredID, let existing = records.first(where: { $0.id == preferredID }) {
            for profileID in existing.enabledProfileIDs {
                unload(id: existing.id, profileID: profileID)
            }
        }
        do {
            let prepared = try await prepare()
            Self.installServiceWorkerNotificationsShim(in: prepared.directory)
            for profileID in records.first(where: { $0.id == prepared.id })?.enabledProfileIDs ?? [] {
                unload(id: prepared.id, profileID: profileID)
            }
            let ext = try await WKWebExtension(resourceBaseURL: prepared.directory)
            try Self.validate(ext)
            let name = ext.displayName ?? prepared.manifest.name
            let decision = await installDecision(id: prepared.id, name: name, extension: ext)
            var record = records.first(where: { $0.id == prepared.id }) ?? ExtensionRecord(
                id: prepared.id,
                name: name,
                version: ext.version ?? prepared.manifest.version,
                source: kind,
                directory: prepared.directory.lastPathComponent,
                enabledProfileIDs: [],
                grantedPermissions: [],
                deniedPermissions: [],
                grantedMatchPatterns: [],
                deniedMatchPatterns: [],
                hasOptionsPage: ext.hasOptionsPage || prepared.manifest.hasOptionsPage,
                summary: ext.displayDescription ?? prepared.manifest.summary
            )
            record.name = name
            record.version = ext.version ?? prepared.manifest.version
            record.source = kind
            record.directory = prepared.directory.lastPathComponent
            record.hasOptionsPage = ext.hasOptionsPage || prepared.manifest.hasOptionsPage
            record.summary = ext.displayDescription ?? prepared.manifest.summary
            record.grantedPermissions = decision.grantedPermissions
            record.deniedPermissions = decision.deniedPermissions
            record.grantedMatchPatterns = decision.grantedPatterns
            record.deniedMatchPatterns = decision.deniedPatterns
            if let profileID = model?.selectedSpace?.profileID, !record.enabledProfileIDs.contains(profileID) {
                record.enabledProfileIDs.append(profileID)
            }
            if let image = ext.icon(for: CGSize(width: 64, height: 64)) {
                iconCache[record.id] = image
            }
            replace(record)
            if let profileID = model?.selectedSpace?.profileID, record.isEnabled(in: profileID) {
                try await load(record, profileID: profileID, existing: ext, reloadPages: true)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func installDecision(id: String, name: String, extension ext: WKWebExtension) async -> PermissionDecision {
        if id == OnePasswordPackage.extensionID {
            return Self.allowAll(ext)
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_EXTENSION_GRANT"] == "1" {
            return PermissionDecision(
                grantedPermissions: ext.requestedPermissions.map(\.rawValue).sorted(),
                deniedPermissions: [],
                grantedPatterns: ext.requestedPermissionMatchPatterns.map(\.string).sorted(),
                deniedPatterns: []
            )
        }
        #endif
        let request = PermissionPrompt.request(
            name: name,
            permissions: ext.requestedPermissions,
            patterns: ext.requestedPermissionMatchPatterns
        )
        let names = ext.requestedPermissions.map(\.rawValue).sorted()
        let patterns = ext.requestedPermissionMatchPatterns.map(\.string).sorted()
        guard !names.isEmpty || !patterns.isEmpty else {
            return PermissionDecision(grantedPermissions: [], deniedPermissions: [], grantedPatterns: [], deniedPatterns: [])
        }
        let allowed = await ask(request)
        if allowed {
            return PermissionDecision(grantedPermissions: names, deniedPermissions: [], grantedPatterns: patterns, deniedPatterns: [])
        }
        return PermissionDecision(grantedPermissions: [], deniedPermissions: names, grantedPatterns: [], deniedPatterns: patterns)
    }

    private static func allowAll(_ ext: WKWebExtension) -> PermissionDecision {
        PermissionDecision(
            grantedPermissions: ext.requestedPermissions.map(\.rawValue).sorted(),
            deniedPermissions: [],
            grantedPatterns: ext.requestedPermissionMatchPatterns.map(\.string).sorted(),
            deniedPatterns: []
        )
    }

    /// 1Password's inline menu and native-messaging unlock need `<all_urls>` and the
    /// permissions in its manifest. An older install that denied them, or never asked,
    /// is repaired on the next load. Other extensions still use the install prompt.
    private func ensureOnePasswordAccess(_ record: ExtensionRecord, extension ext: WKWebExtension) -> ExtensionRecord {
        guard record.id == OnePasswordPackage.extensionID else { return record }
        let decision = Self.allowAll(ext)
        var updated = record
        let permissions = Set(updated.grantedPermissions).union(decision.grantedPermissions)
        var patterns = Set(updated.grantedMatchPatterns).union(decision.grantedPatterns)
        patterns.insert("<all_urls>")
        updated.grantedPermissions = permissions.sorted()
        updated.deniedPermissions.removeAll { permissions.contains($0) }
        updated.grantedMatchPatterns = patterns.sorted()
        updated.deniedMatchPatterns.removeAll { patterns.contains($0) }
        if updated != record {
            replace(updated)
        }
        return updated
    }

    private func loadEnabled() async {
        for record in records {
            for profileID in record.enabledProfileIDs {
                do {
                    try await load(record, profileID: profileID)
                } catch {
                    if lastError == nil { lastError = error.localizedDescription }
                }
            }
        }
    }

    private func load(_ record: ExtensionRecord, profileID: UUID, existing: WKWebExtension? = nil, reloadPages: Bool = false) async throws {
        if contexts[profileID]?[record.id] != nil { return }
        let folder = directory.appending(path: record.directory, directoryHint: .isDirectory)
        // Rewrites mybrowser-compat.js. A stale copy can fail to parse, and then no
        // content script in that file runs, including the 1Password authorize ask.
        try? ExtensionWebKitCompat.apply(to: folder)
        OnePasswordPackage.apply(id: record.id, folder: folder)
        Self.installServiceWorkerNotificationsShim(in: folder)
        let ext: WKWebExtension
        if let existing {
            ext = existing
        } else {
            ext = try await WKWebExtension(resourceBaseURL: folder)
            try Self.validate(ext)
        }
        let granted = ensureOnePasswordAccess(record, extension: ext)
        let context = WKWebExtensionContext(for: ext)
        applyIdentity(granted, to: context)
        // Release builds stay inspectable. This is a browser, not an embedded web view.
        context.isInspectable = true
        apply(granted, to: context)
        let controller = controller(for: profileID)
        announceWindow(profileID: profileID, controller: controller)
        do {
            try controller.load(context)
        } catch {
            if context.baseURL.scheme == "chrome-extension" {
                context.baseURL = URL(string: "webkit-extension://\(record.id)/") ?? context.baseURL
                do {
                    try controller.load(context)
                } catch {
                    throw ExtensionInstallError.webKit(error.localizedDescription)
                }
            } else {
                throw ExtensionInstallError.webKit(error.localizedDescription)
            }
        }
        var loaded = contexts[profileID] ?? [:]
        loaded[record.id] = context
        contexts[profileID] = loaded
        // Tabs that opened before this context loaded were announced to the controller
        // only. Tell this extension about them, then reload so document_start scripts run.
        if let model {
            for tab in model.tabs.values where tab.profileID == profileID && tab.isLoaded {
                context.didOpenTab(tab)
            }
            if let selected = model.selectedTab, selected.profileID == profileID {
                context.didActivateTab(selected, previousActiveTab: nil)
            }
        }
        revision &+= 1
        // `load` returns before WebKit installs content scripts when the base URL
        // changed and local storage is still being renamed. The background page is
        // created in that same callback, just before the scripts are added. Reloading
        // here, on the returning path, commits the document with no content scripts.
        if context.hasInjectedContent {
            let token = ObjectIdentifier(context)
            if backgroundWebView(for: context) != nil {
                // The storage callback already ran inside `load`, so the scripts are in.
                model?.reloadWebTabs(in: profileID)
            } else {
                pendingInjectionReload.insert(token)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.reloadTabsWaitingForInjection(token, profileID: profileID)
                }
            }
        }
        noteOnePasswordHealth(context: context, id: record.id)
        if UBOFilterSource.isFullUBO(record, extensionsDirectory: directory) {
            contentBlocker.refresh()
        }
    }

    private func unload(id: String, profileID: UUID) {
        guard let context = contexts[profileID]?[id], let controller = controllers[profileID] else {
            contexts[profileID]?[id] = nil
            return
        }
        try? controller.unload(context)
        backgroundWebViews[ObjectIdentifier(context)] = nil
        contexts[profileID]?[id] = nil
        revision &+= 1
    }

    /// Enabled extensions in one profile, by name. Inspect Extension… shows this list.
    func inspectionTargets(in profileID: UUID) -> [(id: String, name: String)] {
        records
            .filter { $0.isEnabled(in: profileID) }
            .map { (id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Remembers a background web view from the private controller delegate.
    func noteBackgroundWebView(_ webView: WKWebView, for context: WKWebExtensionContext) {
        webView.isInspectable = true
        backgroundWebViews[ObjectIdentifier(context)] = webView
        let profileID = context.webExtensionController?.configuration.identifier
        guard let profileID else { return }
        let token = ObjectIdentifier(context)
        // The delegate runs before `addInjectedContent` returns. The next turn is
        // after those scripts are on the tab's user content controller.
        DispatchQueue.main.async { [weak self] in
            self?.reloadTabsWaitingForInjection(token, profileID: profileID)
        }
    }

    private func reloadTabsWaitingForInjection(_ token: ObjectIdentifier, profileID: UUID) {
        guard pendingInjectionReload.remove(token) != nil else { return }
        model?.reloadWebTabs(in: profileID)
    }

    /// Opens the inspector on an extension's background page. Loads that page first when it is lazy.
    func inspectBackground(extensionID: String, profileID: UUID) {
        guard let context = contexts[profileID]?[extensionID] else { return }
        context.isInspectable = true
        if let webView = backgroundWebView(for: context) {
            WebInspector.open(.inspector, on: webView)
            return
        }
        context.loadBackgroundContent { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let webView = self.backgroundWebView(for: context) else { return }
                WebInspector.open(.inspector, on: webView)
            }
        }
    }

    private func backgroundWebView(for context: WKWebExtensionContext) -> WKWebView? {
        if let stored = backgroundWebViews[ObjectIdentifier(context)] { return stored }
        let selector = NSSelectorFromString("backgroundWebView")
        guard context.responds(to: selector),
              let webView = context.perform(selector)?.takeUnretainedValue() as? WKWebView else { return nil }
        noteBackgroundWebView(webView, for: context)
        return webView
    }

    /// Chrome Web Store ids keep `runtime.id`. The base URL host is that same id.
    /// A fresh context otherwise uses a new UUID host on every launch. WebKit then
    /// renames extension storage asynchronously and only installs content scripts
    /// when that rename finishes, which is after `load` has returned.
    /// Assigning `chrome-extension://` makes `WKWebExtensionController.load` hang instead of
    /// throwing (1Password on macOS 27). Native hosts still get `chrome-extension://<id>/`.
    private func applyIdentity(_ record: ExtensionRecord, to context: WKWebExtensionContext) {
        context.uniqueIdentifier = record.id
        context.inspectionName = record.name
        if let base = URL(string: "webkit-extension://\(record.id)/") {
            context.baseURL = base
        }
    }

    private func apply(_ record: ExtensionRecord, to context: WKWebExtensionContext) {
        for name in record.grantedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name))
        }
        for name in record.deniedPermissions where !record.grantedPermissions.contains(name) {
            context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: name))
        }
        for pattern in record.grantedMatchPatterns {
            guard let match = try? WKWebExtension.MatchPattern(string: pattern) else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: match)
        }
        for pattern in record.deniedMatchPatterns where !record.grantedMatchPatterns.contains(pattern) {
            guard let match = try? WKWebExtension.MatchPattern(string: pattern) else { continue }
            context.setPermissionStatus(.deniedExplicitly, for: match)
        }
    }

    private func announceWindow(profileID: UUID, controller: WKWebExtensionController) {
        guard announcedWindows.insert(profileID).inserted else { return }
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        guard let model else { return }
        for tab in model.tabs.values where tab.profileID == profileID && tab.isLoaded {
            guard openedTabs.insert(tab.id).inserted else { continue }
            snapshots[tab.id] = snapshot(of: tab)
            controller.didOpenTab(tab)
        }
    }

    private func snapshot(of tab: BrowserTab) -> TabSnapshot {
        let pinned = model?.library.item(tab.id)?.section != .tabs && model?.library.item(tab.id) != nil
        return TabSnapshot(title: tab.title, url: tab.url, isLoading: tab.isLoading, isPinned: pinned)
    }

    private func replace(_ record: ExtensionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    private func recordID(matching context: WKWebExtensionContext) -> String? {
        if let profileID = context.webExtensionController?.configuration.identifier,
           let match = contexts[profileID]?.first(where: { $0.value === context }) {
            return match.key
        }
        let identifier = context.uniqueIdentifier
        if records.contains(where: { $0.id == identifier }) { return identifier }
        return nil
    }

    private func observeFocus() {
        guard focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                guard let self, window === NSApp.mainWindow else { return }
                for controller in self.controllers.values {
                    controller.didFocusWindow(self.window)
                }
            }
        }
    }

    private static func validate(_ ext: WKWebExtension) throws {
        let version = Int(ext.manifestVersion)
        guard version == 2 || version == 3 else {
            let message = ext.errors.first?.localizedDescription ?? "The extension manifest could not be loaded."
            if version == 0 {
                throw ExtensionInstallError.webKit(message)
            }
            throw ExtensionInstallError.unsupportedManifest(version)
        }
        let fatal = ext.errors.contains { error in
            let code = (error as NSError).code
            return code == WKWebExtension.Error.invalidManifest.rawValue
                || code == WKWebExtension.Error.unsupportedManifestVersion.rawValue
                || code == WKWebExtension.Error.invalidArchive.rawValue
        }
        if fatal {
            throw ExtensionInstallError.webKit(ext.errors.map(\.localizedDescription).joined(separator: "\n"))
        }
    }

    #if DEBUG
    /// Writes a tiny MV3 extension and installs it into the current profile. Used by snapshot runs.
    func installDebugFixture(autoGrant: Bool) async {
        let root = directory.appending(path: "debug-fixture-src", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Tint","version":"1.0.0","description":"Sample toolbar extension","action":{"default_title":"Tint","default_popup":"popup.html","default_icon":"icon.png"},"permissions":["storage"],"host_permissions":["https://*/*"]}
        """
        let popup = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font:13px -apple-system,sans-serif;margin:16px;width:260px}h1{font-size:14px;margin:0 0 6px}p{margin:0;color:#555}</style></head><body><h1>Tint</h1><p>Extension popup</p></body></html>
        """
        try? manifest.write(to: root.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try? popup.write(to: root.appending(path: "popup.html"), atomically: true, encoding: .utf8)
        try? Self.debugIconPNG().write(to: root.appending(path: "icon.png"))
        clearError()
        isBusy = true
        defer { isBusy = false }
        do {
            let prepared = try await ExtensionPackage.prepare(source: root, into: directory, sourceKind: .folder, preferredID: nil)
            let ext = try await WKWebExtension(resourceBaseURL: prepared.directory)
            try Self.validate(ext)
            let names = ext.requestedPermissions.map(\.rawValue)
            let patterns = ext.requestedPermissionMatchPatterns.map(\.string)
            let decision = autoGrant
                ? PermissionDecision(grantedPermissions: names, deniedPermissions: [], grantedPatterns: patterns, deniedPatterns: [])
                : await installDecision(id: prepared.id, name: ext.displayName ?? "Tint", extension: ext)
            var record = ExtensionRecord(
                id: prepared.id,
                name: ext.displayName ?? "Tint",
                version: ext.version ?? "1.0.0",
                source: .folder,
                directory: prepared.directory.lastPathComponent,
                enabledProfileIDs: [],
                grantedPermissions: decision.grantedPermissions,
                deniedPermissions: decision.deniedPermissions,
                grantedMatchPatterns: decision.grantedPatterns,
                deniedMatchPatterns: decision.deniedPatterns,
                hasOptionsPage: false,
                summary: "Sample toolbar extension"
            )
            if let profileID = model?.selectedSpace?.profileID {
                record.enabledProfileIDs = [profileID]
            }
            if let image = ext.icon(for: CGSize(width: 32, height: 32)) {
                iconCache[record.id] = image
            }
            replace(record)
            if let profileID = record.enabledProfileIDs.first {
                try await load(record, profileID: profileID, existing: ext)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showDebugPermissionPrompt() async {
        _ = await ask(PermissionPrompt.Request(
            extensionName: "Dark Reader",
            permissions: ["storage", "tabs"],
            matchPatterns: ["<all_urls>"]
        ))
    }

    func performDebugPopup() {
        guard let profileID = model?.selectedSpace?.profileID,
              let id = contexts[profileID]?.keys.first else { return }
        performAction(extensionID: id, profileID: profileID, tab: model?.selectedTab)
    }

    private static func debugIconPNG() -> Data {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 0.45, green: 0.28, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 7, yRadius: 7).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
    #endif
}

private struct PermissionDecision: Sendable {
    var grantedPermissions: [String]
    var deniedPermissions: [String]
    var grantedPatterns: [String]
    var deniedPatterns: [String]
}

private struct TabSnapshot: Equatable {
    var title: String
    var url: URL?
    var isLoading: Bool
    var isPinned: Bool
}

private final class AnchorBox {
    weak var view: NSView?
}
