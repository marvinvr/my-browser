import Foundation
import Observation

/// Origin key for notification permission. `https://host`, with a port only when it is not the default.
enum NotificationOrigin {
    static func key(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return key(scheme: scheme, host: host, port: port)
    }

    static func key(scheme: String, host: String, port: Int) -> String? {
        let scheme = scheme.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        var host = host.lowercased()
        guard !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let defaultPort = scheme == "https" ? 443 : 80
        if port <= 0 || port == defaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    /// True when `origin` is already in canonical form.
    static func isKey(_ origin: String) -> Bool {
        guard let url = URL(string: origin) else { return false }
        return key(for: url) == origin
    }

    static func displayHost(_ origin: String) -> String {
        guard let url = URL(string: origin), var host = url.host()?.lowercased(), !host.isEmpty else {
            return origin
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// Same tag, same identifier, so a later notification replaces the earlier one.
    /// An empty tag keeps each notification.
    static func systemIdentifier(profileID: UUID, origin: String, tag: String, noteID: String) -> String {
        let scope = "\(profileID.uuidString.lowercased())|\(origin)"
        if tag.isEmpty {
            return "mb|\(scope)|id|\(safe(noteID))"
        }
        return "mb|\(scope)|tag|\(safe(tag))"
    }

    private static func safe(_ value: String) -> String {
        let trimmed = String(value.prefix(80))
        return String(trimmed.map { character in
            if character.isLetter || character.isNumber || character == "-" || character == "." { return character }
            return "_"
        })
    }
}

/// Allow / Don't Allow / Ask in Settings and the address-bar menu.
enum NotificationSiteChoice: String, Hashable, Sendable, CaseIterable {
    case allow
    case block
    case ask

    var label: String {
        switch self {
        case .allow: "Allow"
        case .block: "Don't Allow"
        case .ask: "Ask"
        }
    }
}

/// Per-origin, per-profile notification decisions. `notification-permissions.json` next to `library.json`.
@Observable
final class NotificationPermissionStore {
    struct Record: Codable, Equatable, Identifiable, Sendable {
        var profileID: UUID
        var origin: String
        var decision: Decision
        var updatedAt: Date

        var id: String { "\(profileID.uuidString)|\(origin)" }
        var host: String { NotificationOrigin.displayHost(origin) }
    }

    enum Decision: String, Codable, Equatable, Sendable {
        case granted
        case denied
    }

    private struct Snapshot: Codable {
        var records: [Record]
    }

    private let fileURL: URL?
    private(set) var records: [Record]

    init(directory: URL?) {
        if let directory {
            fileURL = directory.appending(path: "notification-permissions.json", directoryHint: .notDirectory)
        } else {
            fileURL = nil
        }
        if let fileURL, let snapshot = try? JSONFileStorage.read(Snapshot.self, from: fileURL) {
            records = snapshot.records.filter { NotificationOrigin.isKey($0.origin) }
        } else {
            records = []
        }
    }

    func decision(profileID: UUID, origin: String) -> Decision? {
        records.first { $0.profileID == profileID && $0.origin == origin }?.decision
    }

    func decisions(for profileID: UUID) -> [String: String] {
        var map: [String: String] = [:]
        for record in records where record.profileID == profileID {
            map[record.origin] = record.decision.rawValue
        }
        return map
    }

    var listed: [Record] {
        records.sorted { lhs, rhs in
            if lhs.host != rhs.host { return lhs.host < rhs.host }
            if lhs.origin != rhs.origin { return lhs.origin < rhs.origin }
            return lhs.profileID.uuidString < rhs.profileID.uuidString
        }
    }

    func set(profileID: UUID, origin: String, decision: Decision, at date: Date = .now) {
        guard NotificationOrigin.isKey(origin) else { return }
        var next = records.filter { !($0.profileID == profileID && $0.origin == origin) }
        next.append(Record(profileID: profileID, origin: origin, decision: decision, updatedAt: date))
        records = next
        save()
    }

    func remove(profileID: UUID, origin: String) {
        let next = records.filter { !($0.profileID == profileID && $0.origin == origin) }
        guard next.count != records.count else { return }
        records = next
        save()
    }

    private func save() {
        guard let fileURL else { return }
        try? JSONFileStorage.write(Snapshot(records: records), to: fileURL)
    }
}
