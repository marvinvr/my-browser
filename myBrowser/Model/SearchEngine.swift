import Foundation

nonisolated enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case google, duckDuckGo, kagi, bing, ecosia

    static let defaultsKey = "searchEngine"

    /// The user's choice (UserDefaults), Google by default.
    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        }
    }

    /// Search URL for `query`. `+`, `&`, `#` and non-ASCII characters are percent-encoded
    /// so the engine receives them as part of the query rather than as delimiters.
    func searchURL(for query: String) -> URL {
        let (host, path) = endpoint
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.percentEncodedQuery = "q=\(Self.percentEncodeQuery(query))"
        if let url = components.url { return url }
        preconditionFailure("Search template for \(displayName) did not produce a URL")
    }

    private var endpoint: (host: String, path: String) {
        switch self {
        case .google: ("www.google.com", "/search")
        case .duckDuckGo: ("duckduckgo.com", "/")
        case .kagi: ("kagi.com", "/search")
        case .bing: ("www.bing.com", "/search")
        case .ecosia: ("www.ecosia.org", "/search")
        }
    }

    private static func percentEncodeQuery(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&#")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }
}
