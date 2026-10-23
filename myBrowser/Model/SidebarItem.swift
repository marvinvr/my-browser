import Foundation

/// One row/icon in a Space's sidebar. The tree is built from `parentID`
/// (folders in `.pinned`, members of a `.split`).
/// `.favorites` and `.pinned` items are synced (Phase 2); `.tabs` items are local only.
nonisolated struct SidebarItem: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case site
        case folder
        /// One sidebar row whose panes are `.site` children (`parentID` = this id), left to right.
        case split
    }

    /// Layout direction of a `.split`. Missing means side by side.
    enum SplitAxis: String, Codable, Sendable {
        case horizontal
        case vertical
    }

    enum Section: String, Codable, Sendable, CaseIterable {
        /// Favicon grid at the top. Sites only, flat.
        case favorites
        /// Pinned sites, nested folders, and splits.
        case pinned
        /// Today's unpinned tabs. Root rows are sites and splits. Not synced.
        case tabs
    }

    /// A split is dissolved below this many live members.
    static let minimumSplitMembers = 2
    /// A split never grows past this many live members.
    static let maximumSplitMembers = 4

    var id: UUID
    var spaceID: UUID
    var section: Section
    var kind: Kind
    /// Containing folder (only within `.pinned`), or the split that owns this site.
    /// `nil` = section root.
    var parentID: UUID?
    var title: String
    /// `.site`: pinned home URL (favorites/pinned) or current URL (tabs).
    var url: URL?
    var sortKey: String
    var isExpanded: Bool
    /// This member's share of its split. `nil` means the panes share the space equally.
    /// Only meaningful on a `.site` whose parent is a `.split`. Older `library.json` files omit it.
    var splitFraction: Double?
    /// Layout direction of a `.split`. `nil` means horizontal. Ignored on other kinds.
    /// Older `library.json` files omit it.
    var splitAxis: SplitAxis?
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
        splitFraction: Double? = nil,
        splitAxis: SplitAxis? = nil,
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
        self.splitFraction = splitFraction
        self.splitAxis = splitAxis
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }

    var isFolder: Bool { kind == .folder }
    var isSplit: Bool { kind == .split }
    var isSynced: Bool { section != .tabs }

    /// Axis used to lay a split out. A missing value is horizontal.
    var resolvedSplitAxis: SplitAxis { splitAxis ?? .horizontal }

    /// Share of the split, or nil when this pane should match its siblings.
    var resolvedSplitFraction: Double? {
        guard let splitFraction, splitFraction.isFinite, splitFraction > 0 else { return nil }
        return splitFraction
    }

    /// Per-pane shares in member order. Any missing share makes every pane equal.
    static func displayFractions(for members: [SidebarItem]) -> [Double?] {
        let resolved = members.map(\.resolvedSplitFraction)
        guard !resolved.isEmpty, resolved.allSatisfy({ $0 != nil }) else {
            return Array(repeating: nil, count: members.count)
        }
        return resolved
    }
}
