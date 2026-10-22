import Foundation

/// JSON on disk for `LibraryStore` and `SessionStore`.
///
/// Dates are ISO8601 in UTC (fractional seconds when the instant needs them).
/// Object keys are sorted and the text is pretty-printed so diffs stay stable.
/// Writes replace the destination atomically. A file that cannot be decoded is
/// moved aside to `<name>.corrupt-<date>.json`.
enum JSONFileStorage {
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    private static let wholeSecondStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .gmt)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let style = fractionalStyle
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(style))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let fractional = fractionalStyle
        let wholeSeconds = wholeSecondStyle
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? fractional.parse(string) { return date }
            if let date = try? wholeSeconds.parse(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO8601 date, got \(string)"
            )
        }
        return decoder
    }()

    /// Encodes `value` and replaces `url` atomically, creating parent directories as needed.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    /// Decodes `url`. Returns nil when the file is absent.
    /// Throws after moving the file aside when the contents are not valid JSON for `T`.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileExists(url) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            quarantine(url)
            throw error
        }
    }

    /// Moves `url` to `<name>.corrupt-<date>.json` beside it.
    static func quarantine(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let stamp = Date.now.formatted(fractionalStyle).replacingOccurrences(of: ":", with: "-")
        var destination = folder.appending(path: "\(base).corrupt-\(stamp).json", directoryHint: .notDirectory)
        if fileExists(destination) {
            let suffix = UUID().uuidString.prefix(8)
            destination = folder.appending(path: "\(base).corrupt-\(stamp)-\(suffix).json", directoryHint: .notDirectory)
        }
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
