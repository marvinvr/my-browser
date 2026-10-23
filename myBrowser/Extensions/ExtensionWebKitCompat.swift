import Foundation

/// Lets a Manifest V2 extension that asks for `privacy` or `webRequestBlocking` start on WebKit.
///
/// WebKit delivers `runtime.onConnect` by reading the page's real `browser` object.
/// Replacing that object with a Proxy drops the listener, so this shim only adds
/// missing properties. It does not implement blocking `webRequest`.
nonisolated enum ExtensionWebKitCompat {
    static let scriptName = "mybrowser-compat.js"

    static func apply(to root: URL) throws {
        let manifestURL = root.appending(path: "manifest.json", directoryHint: .notDirectory)
        let data = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard needsCompat(manifest) else { return }

        try shimSource.write(to: root.appending(path: scriptName), atomically: true, encoding: .utf8)
        if var background = dictionary(manifest["background"]) {
            if let page = background["page"] as? String {
                try inject(intoPage: page, root: root)
            } else if background["scripts"] != nil {
                var scripts = stringArray(background["scripts"])
                if scripts.contains(scriptName) == false {
                    scripts.insert(scriptName, at: 0)
                    background["scripts"] = scripts
                    manifest["background"] = background
                }
            }
        }
        if var contentScripts = dictionaryArray(manifest["content_scripts"]) {
            var changed = false
            for index in contentScripts.indices {
                var js = stringArray(contentScripts[index]["js"])
                guard js.isEmpty == false else { continue }
                guard js.contains(scriptName) == false, js.contains("/" + scriptName) == false else { continue }
                js.insert(scriptName, at: 0)
                contentScripts[index]["js"] = js
                changed = true
            }
            if changed {
                manifest["content_scripts"] = contentScripts
            }
        }
        try patchKnownBundles(in: root)
        let out = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: manifestURL)
    }

    private static func needsCompat(_ manifest: [String: Any]) -> Bool {
        let names = stringArray(manifest["permissions"]) + stringArray(manifest["optional_permissions"])
        return names.contains("privacy") || names.contains("webRequestBlocking")
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func dictionaryArray(_ value: Any?) -> [[String: Any]]? {
        if let typed = value as? [[String: Any]] { return typed }
        guard let items = value as? [Any] else { return nil }
        return items.compactMap { $0 as? [String: Any] }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let typed = value as? [String] { return typed }
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { $0 as? String }
    }

    private static func inject(intoPage page: String, root: URL) throws {
        guard let url = fileURL(page, root: root) else { return }
        var html = try String(contentsOf: url, encoding: .utf8)
        guard html.contains(scriptName) == false else { return }
        let tag = "<script src=\"\(scriptName)\"></script>\n"
        if let range = html.range(of: "<script", options: .caseInsensitive) {
            html.insert(contentsOf: tag, at: range.lowerBound)
        } else if let range = html.range(of: "</head>", options: .caseInsensitive) ?? html.range(of: "</body>", options: .caseInsensitive) {
            html.insert(contentsOf: tag, at: range.lowerBound)
        } else {
            html.append(tag)
        }
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// uBO calls two WebKit-incompatible spots directly. Patching the package is enough;
    /// the properties cannot be replaced on the host objects.
    private static func patchKnownBundles(in root: URL) throws {
        let background = root.appending(path: "js/vapi-background.js", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: background.path(percentEncoded: false)) {
            var source = try String(contentsOf: background, encoding: .utf8)
            source = source.replacingOccurrences(
                of: "browser.webRequest.handlerBehaviorChanged();",
                with: "if (typeof browser.webRequest.handlerBehaviorChanged === 'function') browser.webRequest.handlerBehaviorChanged();"
            )
            source = source.replacingOccurrences(
                of: "details.cssOrigin = 'user';",
                with: "if (details) delete details.cssOrigin;"
            )
            try source.write(to: background, atomically: true, encoding: .utf8)
        }
        let serverlist = root.appending(path: "assets/thirdparties/pgl.yoyo.org/as/serverlist", directoryHint: .notDirectory)
        let serverlistText = root.appending(path: "assets/thirdparties/pgl.yoyo.org/as/serverlist.txt", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: serverlist.path(percentEncoded: false)),
           FileManager.default.fileExists(atPath: serverlistText.path(percentEncoded: false)) == false {
            try FileManager.default.copyItem(at: serverlist, to: serverlistText)
        }
    }

    private static func fileURL(_ path: String, root: URL) -> URL? {
        let relative = path.split(separator: "?").first.map(String.init) ?? path
        let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        guard trimmed.isEmpty == false, trimmed.contains("..") == false else { return nil }
        return root.appending(path: trimmed)
    }

    private static let shimSource = """
    (() => {
      if (globalThis.__myBrowserCompat) return;
      globalThis.__myBrowserCompat = true;
      if (typeof requestIdleCallback !== 'function') {
        self.requestIdleCallback = (cb, opts) => {
          const timeout = (opts && opts.timeout) || 1;
          return setTimeout(() => cb({ didTimeout: true, timeRemaining: () => 0 }), Math.min(timeout, 50));
        };
        self.cancelIdleCallback = (id) => clearTimeout(id);
      }
      const root = globalThis.browser || globalThis.chrome;
      if (!root || !root.runtime) return;
      const define = (obj, name, value) => {
        if (!obj) return;
        try { if (obj[name] != null) return; } catch (e) { return; }
        try { Object.defineProperty(obj, name, { value, configurable: true, writable: true }); } catch (e) {}
        try { if (obj[name] == null) obj[name] = value; } catch (e) {}
      };
      const force = (obj, name, value) => {
        try { obj[name] = value; } catch (e) {}
        if (obj[name] === value) return;
        try { Object.defineProperty(obj, name, { value, configurable: true, writable: true }); } catch (e) {}
      };
      try {
        const nativeGetURL = root.runtime.getURL.bind(root.runtime);
        force(root.runtime, 'getURL', function(path) {
          const value = nativeGetURL(path);
          if (typeof value === 'string' && value.length) return value;
          const sample = nativeGetURL('manifest.json');
          const origin = new URL(sample).origin + '/';
          if (!path) return origin;
          return origin + String(path).replace(/^\\//, '');
        });
      } catch (e) {}
      const setting = () => ({
        get(details, cb) {
          const result = { value: undefined, levelOfControl: 'not_controllable' };
          if (typeof cb === 'function') cb(result);
          return Promise.resolve(result);
        },
        set(details, cb) { if (typeof cb === 'function') cb(); return Promise.resolve(); },
        clear(details, cb) { if (typeof cb === 'function') cb(); return Promise.resolve(); },
      });
      const category = new Proxy({}, { get: () => setting() });
      try { if (root.privacy == null) define(root, 'privacy', new Proxy({}, { get: () => category })); } catch (e) {}
      if (root.webRequest) {
        try {
          if (typeof root.webRequest.handlerBehaviorChanged !== 'function') {
            force(root.webRequest, 'handlerBehaviorChanged', (cb) => {
              if (typeof cb === 'function') cb();
              return Promise.resolve();
            });
          }
        } catch (e) {}
      }
      if (root.alarms && typeof root.alarms.create === 'function') {
        const nativeCreate = root.alarms.create.bind(root.alarms);
        force(root.alarms, 'create', function(nameOrInfo, infoOrCb) {
          let name;
          let info;
          if (typeof nameOrInfo === 'string') {
            name = nameOrInfo;
            info = infoOrCb && typeof infoOrCb === 'object' ? infoOrCb : {};
          } else {
            info = nameOrInfo && typeof nameOrInfo === 'object' ? nameOrInfo : {};
          }
          if (!info.when && !info.delayInMinutes && !info.periodInMinutes) info.delayInMinutes = 1;
          try { return name !== undefined ? nativeCreate(name, info) : nativeCreate(info); }
          catch (e) { try { return nativeCreate(info); } catch (e2) { return undefined; } }
        });
      }
      const wrapMenu = (menus) => {
        if (!menus || typeof menus.create !== 'function') return;
        const nativeCreate = menus.create.bind(menus);
        const valid = (pattern) => typeof pattern === 'string' && (pattern === '<all_urls>' || /^(https?|wss?|ftp|file|\\*):/i.test(pattern));
        force(menus, 'create', function(props, cb) {
          if (props && typeof props === 'object') {
            for (const key of ['targetUrlPatterns', 'documentUrlPatterns', 'urlPatterns']) {
              if (!Array.isArray(props[key])) continue;
              const kept = props[key].filter(valid);
              if (kept.length) props[key] = kept;
              else delete props[key];
            }
          }
          try { return nativeCreate(props, cb); } catch (e) { return undefined; }
        });
      };
      wrapMenu(root.contextMenus);
      wrapMenu(root.menus);
      const fakeEvent = () => ({
        addListener() {},
        removeListener() {},
        hasListener() { return false; },
      });
      const fillEvents = (obj, names) => {
        if (!obj) return;
        for (const name of names) {
          try { if (obj[name]) continue; } catch (e) { continue; }
          define(obj, name, fakeEvent());
        }
      };
      fillEvents(root.runtime, ['onUpdateAvailable', 'onSuspend', 'onSuspendCanceled']);
      fillEvents(root.webNavigation, ['onCreatedNavigationTarget', 'onBeforeNavigate', 'onDOMContentLoaded', 'onCompleted', 'onErrorOccurred', 'onHistoryStateUpdated', 'onReferenceFragmentUpdated', 'onTabReplaced']);
      fillEvents(root.webRequest, ['onAuthRequired', 'onBeforeRedirect']);
    })();
    """
}
