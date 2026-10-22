import Foundation

/// Chromium `Bookmarks` JSON (Chrome, Brave, Edge, Vivaldi, Arc's User Data, Chromium).
///
/// `bookmark_bar` becomes a pinned folder named "Bookmarks Bar", or its children at the
/// pinned root when `bookmarkBarAsFolder` is false. `other` and `synced` become
/// "Other Bookmarks" and "Mobile Bookmarks". Empty folders and `javascript:` URLs are
/// dropped. The same URL twice in one folder keeps the first.
nonisolated enum ChromiumBookmarkParser {
    struct Options: Sendable {
        var spaceName: String
        var symbol: String = "bookmark.fill"
        var color: SpaceColor = .blue
        var bookmarkBarAsFolder: Bool = true
    }

    static func plan(data: Data, options: Options) -> ImportPlan? {
        guard let root = JSONTree.object(from: data),
              let roots = JSONTree.dictionary(root["roots"]) else { return nil }

        let bar = nodes(in: roots["bookmark_bar"])
        let other = nodes(in: roots["other"])
        let synced = nodes(in: roots["synced"])

        var pinned: [ImportNode] = []
        if options.bookmarkBarAsFolder {
            if !bar.isEmpty {
                pinned.append(.folder(title: "Bookmarks Bar", children: bar))
            }
        } else {
            pinned.append(contentsOf: bar)
        }
        if !other.isEmpty {
            pinned.append(.folder(title: "Other Bookmarks", children: other))
        }
        if !synced.isEmpty {
            pinned.append(.folder(title: "Mobile Bookmarks", children: synced))
        }
        guard !pinned.isEmpty else { return ImportPlan.empty }

        let name = options.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let spaceName = name.isEmpty ? "Imported" : name
        let symbol = options.symbol.isEmpty ? "bookmark.fill" : options.symbol
        return ImportPlan(
            profiles: [ImportPlan.Profile(key: "chromium", name: spaceName)],
            spaces: [
                ImportPlan.Space(
                    name: spaceName,
                    symbol: symbol,
                    emoji: nil,
                    color: options.color,
                    profileKey: "chromium",
                    favorites: [],
                    pinned: pinned,
                    tabs: []
                )
            ],
            notes: []
        )
    }

    /// Children of a root folder, cleaned. The root folder itself is not returned.
    private static func nodes(in any: Any?) -> [ImportNode] {
        guard let folder = JSONTree.dictionary(any) else { return [] }
        return clean(JSONTree.array(folder["children"]) ?? [])
    }

    private static func clean(_ children: [Any]) -> [ImportNode] {
        var seen: Set<String> = []
        var nodes: [ImportNode] = []
        for child in children {
            guard let object = JSONTree.dictionary(child) else { continue }
            let type = JSONTree.string(object["type"]) ?? ""
            if type == "url" {
                guard let node = site(object, seen: &seen) else { continue }
                nodes.append(node)
            } else if type == "folder" {
                let nested = clean(JSONTree.array(object["children"]) ?? [])
                guard !nested.isEmpty else { continue }
                nodes.append(.folder(title: title(object, fallback: "Folder"), children: nested))
            }
        }
        return nodes
    }

    private static func site(_ object: [String: Any], seen: inout Set<String>) -> ImportNode? {
        let raw = JSONTree.string(object["url"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, !raw.lowercased().hasPrefix("javascript:") else { return nil }
        guard seen.insert(raw).inserted else { return nil }
        guard let url = URL(string: raw), url.scheme != nil else { return nil }
        return .site(title: title(object, fallback: url.host ?? "Untitled"), url: url)
    }

    private static func title(_ object: [String: Any], fallback: String) -> String {
        let name = JSONTree.string(object["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? fallback : name
    }
}
