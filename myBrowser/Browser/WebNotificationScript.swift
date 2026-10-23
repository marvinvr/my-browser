import Foundation

/// Page-world Notification API. WebKit's public macOS API does not provide one.
enum WebNotificationScript {
    static let marker = "__mybrowserNotificationShim"
    static let handlerName = "mybrowserNotifications"

    static func source(decisions: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: decisions, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return body.replacingOccurrences(of: "__MB_DECISIONS__", with: json)
    }

    static func permissionUpdate(_ value: String) -> String {
        "window.__mbSetPermission && window.__mbSetPermission(\(jsString(value)))"
    }

    /// Walks same-origin frames so a click still finds the Notification object.
    static func callbackScript(kind: String, noteID: String) -> String {
        """
        (function notify(win) {
          try {
            if (win.__mbNotify && win.__mbNotify(\(jsString(kind)), \(jsString(noteID)))) return true;
          } catch (e) {}
          var frames = win.frames;
          for (var i = 0; i < frames.length; i++) {
            try { if (notify(frames[i])) return true; } catch (e) {}
          }
          return false;
        })(window)
        """
    }

    static func jsString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\u{2028}": escaped += "\\u2028"
            case "\u{2029}": escaped += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    private static let body = """
    (function () {
      if (window.__mybrowserNotificationShim) return;
      window.__mybrowserNotificationShim = true;
      var channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mybrowserNotifications;
      var notifications = new Map();
      var embedded = __MB_DECISIONS__;
      var seeded = embedded[location.origin];
      if (!window.__mbNotificationPermission) {
        window.__mbNotificationPermission = seeded || "default";
      }

      function normalize(value) {
        return value === "granted" || value === "denied" ? value : "default";
      }

      window.__mbSetPermission = function (value) {
        window.__mbNotificationPermission = normalize(value);
      };

      function call(payload) {
        if (!channel || !channel.postMessage) {
          return Promise.resolve({ ok: false, permission: "denied" });
        }
        try {
          return Promise.resolve(channel.postMessage(payload)).then(
            function (value) { return value || {}; },
            function () { return { ok: false, permission: "denied" }; }
          );
        } catch (e) {
          return Promise.resolve({ ok: false, permission: "denied" });
        }
      }

      function jsonClone(value) {
        if (value == null) return null;
        try { return JSON.parse(JSON.stringify(value)); }
        catch (e) { return null; }
      }

      function absolute(url) {
        if (!url) return "";
        try { return new URL(String(url), location.href).href; }
        catch (e) { return ""; }
      }

      function fire(note, type) {
        var event = new Event(type);
        try { note.dispatchEvent(event); } catch (e) {}
        var handler = note["on" + type];
        if (typeof handler === "function") {
          try { handler.call(note, event); } catch (e) {}
        }
      }

      function deliver(note) {
        return call({
          kind: "show",
          id: note._id,
          title: note.title,
          body: note.body,
          icon: note.icon,
          tag: note.tag,
          silent: note.silent,
          data: jsonClone(note.data)
        }).then(function (result) {
          if (result && result.ok) {
            fire(note, "show");
            return true;
          }
          fire(note, "error");
          throw new TypeError("Failed to show notification");
        });
      }

      var MB = class Notification extends EventTarget {
        constructor(title, options) {
          super();
          if (MB.permission !== "granted") {
            throw new TypeError("Failed to construct 'Notification': permission is not granted");
          }
          options = options || {};
          this.title = title == null ? "" : String(title);
          this.body = options.body == null ? "" : String(options.body);
          this.icon = absolute(options.icon);
          this.tag = options.tag == null ? "" : String(options.tag);
          this.silent = !!options.silent;
          this.data = options.data;
          this.lang = options.lang == null ? "" : String(options.lang);
          this.dir = options.dir || "auto";
          this.onclick = null;
          this.onshow = null;
          this.onerror = null;
          this.onclose = null;
          this._closed = false;
          this._id = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now()) + Math.random();
          notifications.set(this._id, this);
          this._shown = deliver(this);
        }
        static get permission() {
          return window.__mbNotificationPermission || "default";
        }
        static requestPermission(callback) {
          var gesture = !!(navigator.userActivation && navigator.userActivation.isActive);
          return call({ kind: "request", gesture: gesture }).then(function (result) {
            var value = normalize(result && result.permission);
            window.__mbSetPermission(value);
            if (typeof callback === "function") callback(value);
            return value;
          });
        }
        close() {
          if (this._closed) return;
          this._closed = true;
          notifications.delete(this._id);
          call({ kind: "close", id: this._id, tag: this.tag });
          fire(this, "close");
        }
      };

      window.__mbNotify = function (kind, id) {
        var note = notifications.get(id);
        if (!note) return false;
        if (kind === "click") {
          fire(note, "click");
          return true;
        }
        if (kind === "close") {
          if (!note._closed) {
            note._closed = true;
            notifications.delete(id);
            fire(note, "close");
          }
          return true;
        }
        return false;
      };

      var installed = false;
      try {
        Object.defineProperty(window, "Notification", { configurable: true, writable: true, value: MB });
        installed = window.Notification === MB;
      } catch (e) {}
      if (!installed) {
        try {
          window.Notification = MB;
          installed = window.Notification === MB;
        } catch (e2) {}
      }
      if (!installed && window.Window) {
        try {
          Object.defineProperty(Window.prototype, "Notification", { configurable: true, writable: true, value: MB });
        } catch (e3) {}
      }

      function status(state) {
        var status = {};
        try { status = new EventTarget(); } catch (e) {}
        status.state = state;
        status.name = "notifications";
        status.onchange = null;
        return status;
      }

      function wrapPermissions() {
        var permissions = navigator.permissions;
        if (!permissions || permissions.__mbWrapped || typeof permissions.query !== "function") return;
        var original = permissions.query.bind(permissions);
        var wrapped = function (desc) {
          var name = desc && typeof desc === "object" ? desc.name : desc;
          if (name === "notifications") {
            return call({ kind: "query" }).then(function (result) {
              var raw = normalize(result && result.permission);
              window.__mbSetPermission(raw);
              return status(raw === "default" ? "prompt" : raw);
            });
          }
          return original(desc);
        };
        try {
          permissions.query = wrapped;
          permissions.__mbWrapped = true;
        } catch (e) {}
      }
      wrapPermissions();

      try {
        var proto = window.ServiceWorkerRegistration && ServiceWorkerRegistration.prototype;
        if (proto && !proto.__mbShowNotification) {
          proto.__mbShowNotification = true;
          proto.showNotification = function (title, options) {
            try {
              var note = new MB(title, options || {});
              return note._shown.then(function () {});
            } catch (e) {
              return Promise.reject(e);
            }
          };
        }
      } catch (e) {}

      call({ kind: "query" }).then(function (result) {
        if (result && result.permission) window.__mbSetPermission(result.permission);
      });
    })();
    """
}
