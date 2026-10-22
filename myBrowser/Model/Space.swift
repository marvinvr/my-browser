import Foundation

/// A Space: its own sidebar contents and its own profile. Synced (Phase 2).
nonisolated struct Space: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// SF Symbol name. Shown when `emoji` is nil.
    var symbol: String
    /// Imported emoji, drawn in place of `symbol`. Missing on older `library.json` files.
    var emoji: String?
    var color: SpaceColor
    var profileID: UUID
    var sortKey: String
    var modifiedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "circle.fill",
        emoji: String? = nil,
        color: SpaceColor = .blue,
        profileID: UUID,
        sortKey: String,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.emoji = emoji
        self.color = color
        self.profileID = profileID
        self.sortKey = sortKey
        self.modifiedAt = modifiedAt
    }
}
