import CryptoKit
import Foundation

/// The fields myBrowser needs out of `manifest.json` before WebKit parses the rest.
nonisolated struct ExtensionManifest: Equatable, Sendable {
    var name: String
    var version: String
    var manifestVersion: Int
    var summary: String
    var geckoID: String?
    var publicKey: Data?
    var hasOptionsPage: Bool
    var iconRelativePath: String?

    /// Reads and checks `manifest.json` at the extension root (or one folder down).
    static func load(from directory: URL) throws -> (root: URL, manifest: ExtensionManifest) {
        guard let root = extensionRoot(in: directory) else { throw ExtensionInstallError.noManifest }
        let url = root.appending(path: "manifest.json", directoryHint: .notDirectory)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExtensionInstallError.invalidManifest("manifest.json could not be read.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionInstallError.invalidManifest("manifest.json is not a JSON object.")
        }
        let manifest = try parse(json, root: root)
        return (root, manifest)
    }

    static func parse(_ json: [String: Any], root: URL) throws -> ExtensionManifest {
        let version = manifestVersion(json["manifest_version"])
        guard let version else {
            throw ExtensionInstallError.invalidManifest("manifest_version is missing.")
        }
        guard version == 2 || version == 3 else {
            throw ExtensionInstallError.unsupportedManifest(version)
        }
        guard let name = nonEmptyString(json["name"]) else {
            throw ExtensionInstallError.invalidManifest("name is missing.")
        }
        guard let extensionVersion = nonEmptyString(json["version"]) else {
            throw ExtensionInstallError.invalidManifest("version is missing.")
        }
        let summary = nonEmptyString(json["description"]) ?? ""
        return ExtensionManifest(
            name: localized(name, json: json, root: root) ?? name,
            version: extensionVersion,
            manifestVersion: version,
            summary: localized(summary, json: json, root: root) ?? summary,
            geckoID: geckoID(in: json),
            publicKey: publicKey(json["key"]),
            hasOptionsPage: hasOptionsPage(json),
            iconRelativePath: iconPath(json)
        )
    }

    /// Stable id when the package has no Chrome key and no store id.
    static func localID(for manifest: ExtensionManifest) -> String {
        let basis = Data("\(manifest.name)\n\(manifest.version)\n\(manifest.summary)".utf8)
        let digest = SHA256.hash(data: basis)
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "local-\(hex)"
    }

    static func directoryName(for id: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let mapped = id.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) }
        let name = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "extension" : name
    }

    private static func extensionRoot(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appending(path: "manifest.json").path(percentEncoded: false)) {
            return directory
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let nested = children.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !url.lastPathComponent.hasPrefix("__MACOSX")
                && fileManager.fileExists(atPath: url.appending(path: "manifest.json").path(percentEncoded: false))
        }
        return nested.count == 1 ? nested[0] : nil
    }

    private static func manifestVersion(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double, number.rounded() == number { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func publicKey(_ value: Any?) -> Data? {
        guard let string = value as? String else { return nil }
        let cleaned = string.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        return Data(base64Encoded: cleaned)
    }

    private static func hasOptionsPage(_ json: [String: Any]) -> Bool {
        if json["options_page"] is String { return true }
        if let ui = json["options_ui"] as? [String: Any], ui["page"] is String { return true }
        return false
    }

    private static func geckoID(in json: [String: Any]) -> String? {
        for key in ["browser_specific_settings", "applications"] {
            guard let container = json[key] as? [String: Any],
                  let gecko = container["gecko"] as? [String: Any],
                  let id = nonEmptyString(gecko["id"]) else { continue }
            return id
        }
        return nil
    }

    private static func iconPath(_ json: [String: Any]) -> String? {
        if let icons = json["icons"] as? [String: Any], let path = bestIcon(icons) { return path }
        if let action = (json["action"] as? [String: Any]) ?? (json["browser_action"] as? [String: Any]) {
            if let path = action["default_icon"] as? String { return path }
            if let icons = action["default_icon"] as? [String: Any], let path = bestIcon(icons) { return path }
        }
        return nil
    }

    private static func bestIcon(_ icons: [String: Any]) -> String? {
        let ranked = icons.compactMap { key, value -> (Int, String)? in
            guard let path = value as? String, let size = Int(key) else { return nil }
            return (size, path)
        }.sorted { lhs, rhs in
            let left = abs(lhs.0 - 32)
            let right = abs(rhs.0 - 32)
            if left == right { return lhs.0 > rhs.0 }
            return left < right
        }
        return ranked.first?.1
    }

    /// Resolves `__MSG_key__` from `_locales/<default_locale>/messages.json` when that file is present.
    private static func localized(_ text: String, json: [String: Any], root: URL) -> String? {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return text }
        let key = String(text.dropFirst(6).dropLast(2))
        let locale = (json["default_locale"] as? String) ?? "en"
        for name in [locale, "en"] {
            let url = root.appending(path: "_locales/\(name)/messages.json", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = messages[key] as? [String: Any],
                  let message = entry["message"] as? String,
                  !message.isEmpty else { continue }
            return message
        }
        return text
    }
}
