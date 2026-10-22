import Foundation

/// Turns what the user typed into the command bar into a URL to load.
nonisolated enum URLInput {
    enum Resolution: Equatable, Sendable {
        case url(URL)
        case search(String)
    }

    /// URL if the input looks like one (scheme, localhost[:port], IP, host.tld without spaces), else search.
    static func resolve(_ input: String) -> Resolution {
        // TODO(worker D): real heuristics + tests.
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return .url(url) }
        return .search(trimmed)
    }

    static func url(for input: String, engine: SearchEngine = .current) -> URL {
        switch resolve(input) {
        case .url(let url): url
        case .search(let query): engine.searchURL(for: query)
        }
    }
}
