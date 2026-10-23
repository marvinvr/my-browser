import CryptoKit
import Foundation
import SQLite3

/// One installed uBlock Origin package and the filter text selected for a profile.
nonisolated struct UBOFilterSet: Sendable {
    var profileID: UUID
    var extensionID: String
    struct List: Sendable {
        var name: String
        var text: String
    }

    var lists: [List]
    var userFilters: String
    var whitelist: [String]
    var hash: String
    var missing: [String]
    var packageFallbacks: [String]

    var listTexts: [String] { lists.map(\.text) }
}

nonisolated enum UBOFilterSource {
    static let storeExtensionID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
    private static let bundleID = "ch.marvinvr.mybrowser"

    static func isFullUBO(_ record: ExtensionRecord, extensionsDirectory: URL) -> Bool {
        guard record.name == "uBlock Origin" else { return false }
        let assets = extensionsDirectory
            .appending(path: record.directory, directoryHint: .isDirectory)
            .appending(path: "assets/assets.json", directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: assets.path)
    }

    static func storageDatabaseURL(profileID: UUID, extensionID: String) -> URL {
        let uuid = profileID.uuidString.uppercased()
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/WebKit/\(bundleID)/WebExtensions/\(uuid)/\(extensionID)/LocalStorage.db")
    }

    /// Reads `extension_storage`. Copies the database aside when the live file is locked.
    static func readStorage(profileID: UUID, extensionID: String) -> [String: String] {
        let url = storageDatabaseURL(profileID: profileID, extensionID: extensionID)
        if let rows = query(url) { return rows }
        return copyAndQuery(url) ?? [:]
    }

    static func makeSet(
        profileID: UUID,
        extensionID: String,
        packageRoot: URL,
        storage: [String: String],
        capabilities: WebKitRuleCapabilities,
        compilerVersion: Int
    ) -> UBOFilterSet? {
        guard let assets = loadAssets(packageRoot) else { return nil }
        let selected = selectedKeys(storage: storage, assets: assets)
        var lists: [UBOFilterSet.List] = []
        var missing: [String] = []
        var fallbacks: [String] = []
        var hashLines: [String] = [
            "v\(compilerVersion)",
            capabilities.token
        ]
        for key in selected where key != "user-filters" {
            let raw = storage["cache/\(key)"]
            hashLines.append("key:\(key)")
            hashLines.append("raw:\(raw.map(fingerprint) ?? "-")")
            if let raw, let text = text(fromStored: raw), !text.isEmpty {
                lists.append(UBOFilterSet.List(name: key, text: text))
                hashLines.append(sha256(text))
                continue
            }
            if raw != nil { fallbacks.append(key) }
            if let text = packageText(key: key, assets: assets, root: packageRoot) {
                lists.append(UBOFilterSet.List(name: key, text: text))
                hashLines.append(sha256(text))
            } else {
                missing.append(key)
                hashLines.append("missing")
            }
        }
        let user = storage["user-filters"].flatMap { text(fromStored: $0) } ?? ""
        let whitelist = whitelistDirectives(storage)
        hashLines.append("user:\(sha256(user))")
        hashLines.append("wl:\(whitelist.joined(separator: "\n"))")
        return UBOFilterSet(
            profileID: profileID,
            extensionID: extensionID,
            lists: lists,
            userFilters: user,
            whitelist: whitelist,
            hash: sha256(hashLines.joined(separator: "\n")),
            missing: missing,
            packageFallbacks: fallbacks
        )
    }

    static func text(fromStored jsonText: String) -> String? {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("UOSC") {
            return UOSCDecoder.decode(trimmed)?.text
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let string = object as? String {
            if string.hasPrefix("UOSC") { return UOSCDecoder.decode(string)?.text }
            return string
        }
        return nil
    }

    static func strings(fromStored jsonText: String) -> [String]? {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("UOSC"), let list = UOSCDecoder.decode(trimmed)?.stringList {
            return list
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let values = object as? [Any] {
            let strings = values.compactMap { $0 as? String }
            return strings.count == values.count ? strings : nil
        }
        if let string = object as? String {
            if string.hasPrefix("UOSC") { return UOSCDecoder.decode(string)?.stringList }
            let lines = string.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return lines
        }
        return nil
    }

    // MARK: Assets

    private struct Asset {
        var content: String
        var off: Bool
        var localPaths: [String]
    }

    private static func loadAssets(_ root: URL) -> [String: Asset]? {
        let url = root.appending(path: "assets/assets.json")
        guard let data = try? Data(contentsOf: url),
              let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var assets: [String: Asset] = [:]
        for (key, value) in rootObject {
            guard let object = value as? [String: Any] else { continue }
            let content = object["content"] as? String ?? ""
            let off = (object["off"] as? Bool) ?? false
            var locals: [String] = []
            if let one = object["contentURL"] as? String {
                if isLocal(one) { locals.append(one) }
            } else if let many = object["contentURL"] as? [Any] {
                for item in many {
                    guard let path = item as? String, isLocal(path) else { continue }
                    locals.append(path)
                }
            }
            let mins = locals.filter { $0.contains(".min.") }
            let rest = locals.filter { !$0.contains(".min.") }
            assets[key] = Asset(content: content, off: off, localPaths: mins + rest)
        }
        return assets
    }

    private static func isLocal(_ path: String) -> Bool {
        !path.hasPrefix("http://") && !path.hasPrefix("https://") && !path.hasPrefix("//")
    }

    private static func selectedKeys(storage: [String: String], assets: [String: Asset]) -> [String] {
        if let raw = storage["selectedFilterLists"], let keys = strings(fromStored: raw), !keys.isEmpty {
            return keys
        }
        var defaults = assets.filter { $0.value.content == "filters" && !$0.value.off }.map(\.key).sorted()
        if !defaults.contains("user-filters") {
            defaults.insert("user-filters", at: 0)
        }
        return defaults
    }

    private static func packageText(key: String, assets: [String: Asset], root: URL) -> String? {
        guard let asset = assets[key] else { return nil }
        for relative in asset.localPaths {
            let url = root.appending(path: relative)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    private static func whitelistDirectives(_ storage: [String: String]) -> [String] {
        let raw = storage["netWhitelist"] ?? storage["data.whitelist"]
        guard let raw, let values = strings(fromStored: raw) else { return [] }
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted()
    }

    // MARK: Hash

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(_ text: String) -> String {
        "\(text.utf8.count):\(sha256(text))"
    }

    // MARK: SQLite

    private static func query(_ url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)
        var statement: OpaquePointer?
        let sql = "SELECT key, value FROM extension_storage"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(statement, 0),
                  let valueC = sqlite3_column_text(statement, 1) else { continue }
            rows[String(cString: keyC)] = String(cString: valueC)
        }
        return rows
    }

    private static func copyAndQuery(_ url: URL) -> [String: String]? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mb-ubo-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: "LocalStorage.db")
            try FileManager.default.copyItem(at: url, to: destination)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: side.path) {
                    try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: destination.path + suffix))
                }
            }
            defer { try? FileManager.default.removeItem(at: folder) }
            return query(destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }
}
