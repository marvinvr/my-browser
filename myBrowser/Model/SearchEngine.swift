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

    func searchURL(for query: String) -> URL {
        // TODO(worker D): per-engine templates with proper query encoding.
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}
