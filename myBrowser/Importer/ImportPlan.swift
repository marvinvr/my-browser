import Foundation

/// One site or folder produced by a parser. Folders only appear in `.pinned`.
nonisolated enum ImportNode: Sendable, Equatable {
    case site(title: String, url: URL)
    case folder(title: String, children: [ImportNode])

    static func siteCount(in nodes: [ImportNode]) -> Int {
        nodes.reduce(0) { count, node in
            switch node {
            case .site: count + 1
            case .folder(_, let children): count + siteCount(in: children)
            }
        }
    }

    static func folderCount(in nodes: [ImportNode]) -> Int {
        nodes.reduce(0) { count, node in
            switch node {
            case .site: count
            case .folder(_, let children): count + 1 + folderCount(in: children)
            }
        }
    }
}

/// Profiles, spaces, and sidebar trees ready to insert. Parsers build this off the main actor.
nonisolated struct ImportPlan: Sendable, Equatable {
    struct Profile: Sendable, Equatable {
        var key: String
        var name: String
    }

    struct Space: Sendable, Equatable {
        var name: String
        var symbol: String
        var emoji: String?
        var color: SpaceColor
        /// Spaces that share a key share one new `Profile`.
        var profileKey: String
        var favorites: [ImportNode]
        var pinned: [ImportNode]
        var tabs: [ImportNode]
    }

    var profiles: [Profile]
    var spaces: [Space]
    /// Shown after import. Empty when there is nothing to explain.
    var notes: [String]

    var favoriteSiteCount: Int { spaces.reduce(0) { $0 + ImportNode.siteCount(in: $1.favorites) } }
    var pinnedSiteCount: Int { spaces.reduce(0) { $0 + ImportNode.siteCount(in: $1.pinned) } }
    var pinnedFolderCount: Int { spaces.reduce(0) { $0 + ImportNode.folderCount(in: $1.pinned) } }
    var tabCount: Int { spaces.reduce(0) { $0 + ImportNode.siteCount(in: $1.tabs) } }

    static let empty = ImportPlan(profiles: [], spaces: [], notes: [])
}

/// What `LibraryStore.apply` actually inserted.
nonisolated struct ImportResult: Sendable, Equatable {
    var spacesCreated: Int
    var profilesCreated: Int
    var favoriteCount: Int
    var pinnedCount: Int
    var tabCount: Int
    var notes: [String]
    /// New space ids, or the existing space when items were appended there.
    var spaceIDs: [UUID]

    var summary: String {
        var parts: [String] = []
        if spacesCreated > 0 {
            parts.append("Imported \(spacesCreated) \(spacesCreated == 1 ? "space" : "spaces")")
        }
        if favoriteCount > 0 {
            parts.append("\(favoriteCount) \(favoriteCount == 1 ? "favorite" : "favorites")")
        }
        if pinnedCount > 0 {
            parts.append("\(pinnedCount) pinned \(pinnedCount == 1 ? "item" : "items")")
        }
        if tabCount > 0 {
            parts.append("\(tabCount) \(tabCount == 1 ? "tab" : "tabs")")
        }
        if parts.isEmpty { return "Nothing to import" }
        if spacesCreated == 0 { return "Imported " + parts.joined(separator: ", ") }
        return parts.joined(separator: ", ")
    }

    static let empty = ImportResult(
        spacesCreated: 0,
        profilesCreated: 0,
        favoriteCount: 0,
        pinnedCount: 0,
        tabCount: 0,
        notes: [],
        spaceIDs: []
    )
}
