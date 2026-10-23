import Foundation

/// Arc `StorableSidebar.json`.
///
/// `sidebar.containers` holds the window state. `spaces` and `items` are flat lists that
/// alternate an id string with an object. Items point at each other with `parentID` and
/// `childrenIds`. A tab is `data.tab` (`savedURL`, `savedTitle`). A folder is `data.list`.
/// An `itemContainer` is `pinned`, `unpinned`, `topApps`, or `spaceItems` (a space's
/// sidebar, whose pinned/unpinned role is the matching entry in `newContainerIDs`).
/// `topApps` are favorites for one Arc profile, stored once and copied onto every
/// imported space of that profile. Spaces that share an Arc profile share one plan profile.
nonisolated enum ArcSidebarParser {
    struct Read: Sendable {
        var plan: ImportPlan
        /// Unpinned sites in the file, whether or not they were added to the plan.
        var unpinnedSiteCount: Int
    }

    /// `profileNames` maps a Chromium directory basename (`Default`, `Profile 1`) to a display name.
    static func read(data: Data, includeUnpinned: Bool, profileNames: [String: String] = [:]) -> Read? {
        guard let root = JSONTree.object(from: data) else { return nil }
        let sidebar = JSONTree.dictionary(root["sidebar"]) ?? root
        let containers = JSONTree.array(sidebar["containers"]) ?? []

        var spaces: [ImportPlan.Space] = []
        var profiles: [ImportPlan.Profile] = []
        var seenProfiles: Set<String> = []
        var seenSpaceIDs: Set<String> = []
        var unpinnedSiteCount = 0
        var placedFavorites = false

        for containerAny in containers {
            guard let container = JSONTree.dictionary(containerAny) else { continue }
            let items = itemMap(container["items"])
            let spaceObjects = JSONTree.pairedObjects(container["spaces"])
            guard !items.isEmpty || !spaceObjects.isEmpty else { continue }
            let favorites = favoriteNodes(in: container, items: items, profileNames: profileNames)

            for space in spaceObjects {
                let spaceID = JSONTree.string(space["id"]) ?? ""
                if !spaceID.isEmpty, !seenSpaceIDs.insert(spaceID).inserted { continue }

                let identity = profileIdentity(space["profile"], names: profileNames) ?? ("default", profileNames["Default"] ?? "Default")
                if seenProfiles.insert(identity.key).inserted {
                    profiles.append(ImportPlan.Profile(key: identity.key, name: identity.name))
                }

                let roles = containerRoles(space: space, items: items)
                let pinned = tree(under: roles.pinned, items: items)
                let unpinned = flatten(under: roles.unpinned, items: items)
                unpinnedSiteCount += ImportNode.siteCount(in: unpinned)

                let spaceFavorites = favorites[identity.key] ?? []
                if !spaceFavorites.isEmpty { placedFavorites = true }

                let icon = iconParts(space["customInfo"])
                let rawName = JSONTree.string(space["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                spaces.append(ImportPlan.Space(
                    name: rawName.isEmpty ? "Space" : rawName,
                    symbol: icon.symbol,
                    emoji: icon.emoji,
                    color: color(space["customInfo"]),
                    profileKey: identity.key,
                    favorites: spaceFavorites,
                    pinned: pinned,
                    tabs: includeUnpinned ? unpinned : []
                ))
            }
        }

        var notes: [String] = []
        if placedFavorites {
            notes.append("Arc favorites were added to every space of each profile.")
        }
        let plan = ImportPlan(profiles: profiles, spaces: spaces, notes: notes)
        return Read(plan: plan, unpinnedSiteCount: unpinnedSiteCount)
    }

    // MARK: Items

    private static func itemMap(_ any: Any?) -> [String: [String: Any]] {
        var map: [String: [String: Any]] = [:]
        for object in JSONTree.pairedObjects(any) {
            guard let id = JSONTree.string(object["id"]) else { continue }
            map[id] = object
        }
        return map
    }

    private static func containerRole(_ item: [String: Any]) -> String? {
        guard let data = JSONTree.dictionary(item["data"]),
              let box = JSONTree.dictionary(data["itemContainer"]),
              let type = JSONTree.dictionary(box["containerType"]) else { return nil }
        return type.keys.first
    }

    private static func containerRoles(
        space: [String: Any],
        items: [String: [String: Any]]
    ) -> (pinned: String?, unpinned: String?) {
        var pinned: String?
        var unpinned: String?
        for id in JSONTree.strings(space["containerIDs"]) {
            guard let item = items[id] else { continue }
            switch containerRole(item) {
            case "pinned": pinned = id
            case "unpinned": unpinned = id
            default: break
            }
        }
        for tag in JSONTree.taggedIDs(space["newContainerIDs"]) {
            switch tag.tag {
            case "pinned": pinned = tag.id
            case "unpinned": unpinned = tag.id
            default: break
            }
        }
        return (pinned, unpinned)
    }

    private static func favoriteNodes(
        in container: [String: Any],
        items: [String: [String: Any]],
        profileNames: [String: String]
    ) -> [String: [ImportNode]] {
        var byProfile: [String: [ImportNode]] = [:]
        var seen: Set<String> = []

        func add(id: String, identity: (key: String, name: String)) {
            guard seen.insert(id).inserted else { return }
            let sites = flatten(under: id, items: items)
            guard !sites.isEmpty else { return }
            byProfile[identity.key, default: []].append(contentsOf: sites)
        }

        for tag in JSONTree.taggedIDs(container["topAppsContainerIDs"]) {
            let identity = profileIdentity(tag.payload, names: profileNames) ?? ("default", "Default")
            add(id: tag.id, identity: identity)
        }
        for (id, item) in items where containerRole(item) == "topApps" {
            let type = JSONTree.dictionary(item["data"])
                .flatMap { JSONTree.dictionary($0["itemContainer"]) }
                .flatMap { $0["containerType"] }
            let identity = profileIdentity(type, names: profileNames) ?? ("default", "Default")
            add(id: id, identity: identity)
        }
        return byProfile
    }

    /// Pinned tree. Empty folders, `javascript:` URLs, and duplicate URLs in one folder are dropped.
    private static func tree(under containerID: String?, items: [String: [String: Any]]) -> [ImportNode] {
        guard let containerID, let container = items[containerID] else { return [] }
        var trail: Set<String> = [containerID]
        return folderChildren(JSONTree.strings(container["childrenIds"]), items: items, trail: &trail)
    }

    private static func folderChildren(
        _ ids: [String],
        items: [String: [String: Any]],
        trail: inout Set<String>
    ) -> [ImportNode] {
        var seenURLs: Set<String> = []
        var nodes: [ImportNode] = []
        for id in ids {
            guard trail.insert(id).inserted, let item = items[id] else { continue }
            defer { trail.remove(id) }
            let data = JSONTree.dictionary(item["data"]) ?? [:]
            if let tab = JSONTree.dictionary(data["tab"]) {
                if let site = site(item, tab: tab, seen: &seenURLs) {
                    nodes.append(site)
                }
            } else if data["list"] != nil {
                let children = folderChildren(JSONTree.strings(item["childrenIds"]), items: items, trail: &trail)
                guard !children.isEmpty else { continue }
                nodes.append(.folder(title: label(item["title"], fallback: "Folder"), children: children))
            }
        }
        return nodes
    }

    /// Unpinned tabs are a flat list. Nested folders contribute their sites in order.
    private static func flatten(under containerID: String?, items: [String: [String: Any]]) -> [ImportNode] {
        guard let containerID, let container = items[containerID] else { return [] }
        var trail: Set<String> = [containerID]
        var seenURLs: Set<String> = []
        var nodes: [ImportNode] = []
        appendSites(
            JSONTree.strings(container["childrenIds"]),
            items: items,
            trail: &trail,
            seen: &seenURLs,
            into: &nodes
        )
        return nodes
    }

    private static func appendSites(
        _ ids: [String],
        items: [String: [String: Any]],
        trail: inout Set<String>,
        seen: inout Set<String>,
        into nodes: inout [ImportNode]
    ) {
        for id in ids {
            guard trail.insert(id).inserted, let item = items[id] else { continue }
            defer { trail.remove(id) }
            let data = JSONTree.dictionary(item["data"]) ?? [:]
            if let tab = JSONTree.dictionary(data["tab"]) {
                if let site = site(item, tab: tab, seen: &seen) {
                    nodes.append(site)
                }
            } else if data["list"] != nil || containerRole(item) != nil {
                appendSites(JSONTree.strings(item["childrenIds"]), items: items, trail: &trail, seen: &seen, into: &nodes)
            }
        }
    }

    private static func site(_ item: [String: Any], tab: [String: Any], seen: inout Set<String>) -> ImportNode? {
        let raw = JSONTree.string(tab["savedURL"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, !raw.lowercased().hasPrefix("javascript:") else { return nil }
        guard seen.insert(raw).inserted else { return nil }
        guard let url = URL(string: raw), url.scheme != nil else { return nil }
        let saved = JSONTree.string(tab["savedTitle"])
        let title = label(item["title"], fallback: label(saved, fallback: url.host ?? "Untitled"))
        return .site(title: title, url: url)
    }

    private static func label(_ any: Any?, fallback: String) -> String {
        let text = JSONTree.string(any)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    // MARK: Space chrome

    private static func profileIdentity(_ any: Any?, names: [String: String]) -> (key: String, name: String)? {
        guard let dictionary = JSONTree.dictionary(any) else { return nil }
        if let wrapped = dictionary["topApps"] {
            return profileIdentity(wrapped, names: names)
        }
        if dictionary.count == 1, dictionary["_0"] != nil {
            return profileIdentity(dictionary["_0"], names: names)
        }
        if let custom = dictionary["custom"] {
            let body = JSONTree.dictionary(JSONTree.unwrap(custom)) ?? [:]
            let base = JSONTree.string(body["directoryBasename"]) ?? "Profile"
            return ("custom:\(base)", names[base] ?? base)
        }
        if dictionary["default"] != nil {
            return ("default", names["Default"] ?? "Default")
        }
        return nil
    }

    private static func iconParts(_ any: Any?) -> (symbol: String, emoji: String?) {
        let info = JSONTree.dictionary(any)
        let iconType = JSONTree.dictionary(info?["iconType"]) ?? [:]
        if let emoji = JSONTree.string(iconType["emoji_v2"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !emoji.isEmpty {
            return (ArcIconMap.symbol(forEmoji: emoji), emoji)
        }
        if let code = JSONTree.int(iconType["emoji"]), let scalar = UnicodeScalar(code) {
            let emoji = String(Character(scalar))
            return (ArcIconMap.symbol(forEmoji: emoji), emoji)
        }
        if let name = JSONTree.string(iconType["icon"]) ?? JSONTree.string(iconType["symbol"]) {
            return (ArcIconMap.symbol(for: name), nil)
        }
        return ("circle.fill", nil)
    }

    private static func color(_ any: Any?) -> SpaceColor {
        let info = JSONTree.dictionary(any)
        let theme = JSONTree.dictionary(info?["windowTheme"])
        let palette = JSONTree.dictionary(theme?["primaryColorPalette"])
        let mid = JSONTree.dictionary(palette?["midTone"])
        guard let red = JSONTree.double(mid?["red"]),
              let green = JSONTree.double(mid?["green"]),
              let blue = JSONTree.double(mid?["blue"]) else { return .blue }
        return SpaceColor.nearest(red: red, green: green, blue: blue)
    }
}
