import Foundation

/// The Chrome 1Password build loads its inline menu by `import()` from a content script.
/// That import does not run in a WebKit content script, so the menu never starts.
/// The bundle is registered in the manifest instead, and the import is turned into a
/// resolved promise so the same file is not injected twice.
nonisolated enum OnePasswordPackage {
    static let extensionID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    private static let bootstrap = "inline/inject-content-scripts.js"
    private static let inlineBundle = "inline/injected.js"
    private static let importNeedle = "=>import(r)"
    private static let importReplacement = "=>Promise.resolve(/* mb-no-dynamic-import */)"

    static func apply(id: String, folder: URL) {
        guard id == extensionID else { return }
        if neutralizeBootstrapImport(in: folder) {
            registerInlineBundle(in: folder)
        }
        // The package's connect-src lists 1Password servers and not its own origin.
        // The service worker fetches its WASM from that origin. WebKit blocks the
        // fetch, the core never starts, and the popup stays empty.
        allowOwnOriginFetch(in: folder)
    }

    /// Returns true when the bootstrap will not also `import()` the inline bundle.
    private static func neutralizeBootstrapImport(in folder: URL) -> Bool {
        let file = folder.appending(path: bootstrap, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)),
              var body = try? String(contentsOf: file, encoding: .utf8) else { return false }
        if body.contains(importNeedle) {
            body = body.replacingOccurrences(of: importNeedle, with: importReplacement)
            try? body.write(to: file, atomically: true, encoding: .utf8)
            return true
        }
        return body.contains("mb-no-dynamic-import")
    }

    private static func registerInlineBundle(in folder: URL) {
        let bundle = folder.appending(path: inlineBundle, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: bundle.path(percentEncoded: false)) else { return }
        let manifestURL = folder.appending(path: "manifest.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var scripts = manifest["content_scripts"] as? [[String: Any]] else { return }
        let listed = scripts.contains { entry in
            let js = entry["js"] as? [String] ?? []
            return js.contains(inlineBundle)
        }
        guard listed == false else { return }
        scripts.append([
            "matches": ["<all_urls>"],
            "all_frames": true,
            "js": [inlineBundle],
            "run_at": "document_start",
        ])
        manifest["content_scripts"] = scripts
        guard let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: manifestURL)
    }

    /// Adds `'self'` to `connect-src` so the service worker can fetch its own WASM.
    private static func allowOwnOriginFetch(in folder: URL) {
        let manifestURL = folder.appending(path: "manifest.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if var policy = manifest["content_security_policy"] as? [String: Any],
           let pages = policy["extension_pages"] as? String {
            let updated = addingSelf(toConnectSrc: pages)
            guard updated != pages else { return }
            policy["extension_pages"] = updated
            manifest["content_security_policy"] = policy
        } else if let policy = manifest["content_security_policy"] as? String {
            let updated = addingSelf(toConnectSrc: policy)
            guard updated != policy else { return }
            manifest["content_security_policy"] = updated
        } else {
            return
        }
        guard let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: manifestURL)
    }

    private static func addingSelf(toConnectSrc policy: String) -> String {
        var parts = policy.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for index in parts.indices {
            let trimmed = parts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("connect-src") else { continue }
            found = true
            let tokens = trimmed.split(separator: " ").map(String.init)
            if tokens.contains("'self'") { continue }
            parts[index] += " 'self'"
        }
        if found { return parts.joined(separator: ";") }
        if policy.contains("default-src") {
            return policy + "; connect-src 'self'"
        }
        return policy
    }
}
