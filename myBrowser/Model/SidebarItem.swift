import Foundation

/// One row/icon in a Space's sidebar. The tree is built from `parentID` (folders in `.pinned`).
/// `.favorites` and `.pinned` items are synced (Phase 2); `.tabs` items are local only.
nonisolated struct SidebarItem: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case site, folder }
    enum Section: String, Codable, Sendable, CaseIterable {
        /// Favicon grid at the top. Sites only, flat.
        case favorites
        /// Pinned sites and nested folders.
        case pinned
        /// Today's unpinned tabs. Sites only, flat. Not synced.
        case tabs
    }

    var id: UUID
    var spaceID: UUID
    var section: Section
    var kind: Kind
    /// Containing folder (only within `.pinned`). `nil` = section root.
    var parentID: UUID?
    var title: String
    /// `.site`: pinned home URL (favorites/pinned) or current URL (tabs).
    var url: URL?
    var sortKey: String
    var isExpanded: Bool
    var createdAt: Date
    var modifiedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        spaceID: UUID,
        section: Section,
        kind: Kind,
        parentID: UUID? = nil,
        title: String,
        url: URL? = nil,
        sortKey: String,
        isExpanded: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.spaceID = spaceID
        self.section = section
        self.kind = kind
        self.parentID = parentID
        self.title = title
        self.url = url
        self.sortKey = sortKey
        self.isExpanded = isExpanded
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }

    var isFolder: Bool { kind == .folder }
    var isSynced: Bool { section != .tabs }
}
