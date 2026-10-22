import Foundation

nonisolated enum ExtensionSource: String, Codable, Sendable {
    case folder
    case zip
    case xpi
    case crx
    case chromeWebStore
}

/// One installed extension, as written to `extensions.json`.
nonisolated struct ExtensionRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var version: String
    var source: ExtensionSource
    /// Folder name under `Extensions/`. Not always equal to `id` (`@` in a Firefox id stays, `/` does not).
    var directory: String
    var enabledProfileIDs: [UUID]
    var grantedPermissions: [String]
    var deniedPermissions: [String]
    var grantedMatchPatterns: [String]
    var deniedMatchPatterns: [String]
    var hasOptionsPage: Bool
    var summary: String

    var isEnabled: Bool { !enabledProfileIDs.isEmpty }

    func isEnabled(in profileID: UUID) -> Bool {
        enabledProfileIDs.contains(profileID)
    }
}

/// `Extensions/extensions.json`.
nonisolated struct ExtensionCatalogFile: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var extensions: [ExtensionRecord]

    static let currentSchema = 1

    init(extensions: [ExtensionRecord]) {
        schemaVersion = Self.currentSchema
        self.extensions = extensions
    }
}

enum ExtensionCatalogStore {
    static func fileURL(in directory: URL) -> URL {
        directory.appending(path: "extensions.json", directoryHint: .notDirectory)
    }

    static func load(from directory: URL) throws -> [ExtensionRecord] {
        guard let file = try JSONFileStorage.read(ExtensionCatalogFile.self, from: fileURL(in: directory)) else {
            return []
        }
        return file.extensions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ records: [ExtensionRecord], to directory: URL) throws {
        let normalized = records
            .map(normalized)
            .sorted { $0.id < $1.id }
        try JSONFileStorage.write(ExtensionCatalogFile(extensions: normalized), to: fileURL(in: directory))
    }

    private static func normalized(_ record: ExtensionRecord) -> ExtensionRecord {
        var copy = record
        copy.enabledProfileIDs = uniqueSorted(copy.enabledProfileIDs)
        copy.grantedPermissions = uniqueSorted(copy.grantedPermissions)
        copy.deniedPermissions = uniqueSorted(copy.deniedPermissions.subtracting(copy.grantedPermissions))
        copy.grantedMatchPatterns = uniqueSorted(copy.grantedMatchPatterns)
        copy.deniedMatchPatterns = uniqueSorted(copy.deniedMatchPatterns.subtracting(copy.grantedMatchPatterns))
        return copy
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func uniqueSorted(_ values: [UUID]) -> [UUID] {
        Array(Set(values)).sorted { $0.uuidString < $1.uuidString }
    }
}

private extension Array where Element == String {
    func subtracting(_ other: [String]) -> [String] {
        let drop = Set(other)
        return filter { !drop.contains($0) }
    }
}
