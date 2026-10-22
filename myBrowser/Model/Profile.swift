import Foundation

/// A browsing profile. Its `id` is the identifier of the `WKWebsiteDataStore` that isolates
/// cookies, storage and caches. Synced (Phase 2).
nonisolated struct Profile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var modifiedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), name: String, modifiedAt: Date = .now) {
        self.id = id
        self.name = name
        self.modifiedAt = modifiedAt
    }
}
