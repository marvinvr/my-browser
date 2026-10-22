import Foundation
import Testing
@testable import myBrowser

@MainActor
struct SearchEngineTests {
    @Test func templates() {
        #expect(SearchEngine.google.searchURL(for: "cats").absoluteString == "https://www.google.com/search?q=cats")
        #expect(SearchEngine.duckDuckGo.searchURL(for: "cats").absoluteString == "https://duckduckgo.com/?q=cats")
        #expect(SearchEngine.kagi.searchURL(for: "cats").absoluteString == "https://kagi.com/search?q=cats")
        #expect(SearchEngine.bing.searchURL(for: "cats").absoluteString == "https://www.bing.com/search?q=cats")
        #expect(SearchEngine.ecosia.searchURL(for: "cats").absoluteString == "https://www.ecosia.org/search?q=cats")
    }

    @Test func encodesReservedCharactersAndUnicode() {
        let query = "a+b & c#d ü"
        let url = SearchEngine.google.searchURL(for: query)
        #expect(url.absoluteString == "https://www.google.com/search?q=a%2Bb%20%26%20c%23d%20%C3%BC")
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        #expect(value == query)

        for engine in SearchEngine.allCases {
            let engineURL = engine.searchURL(for: query)
            let roundTrip = URLComponents(url: engineURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            #expect(roundTrip == query)
            #expect(engineURL.absoluteString.contains("a%2Bb"))
            #expect(engineURL.absoluteString.contains("%26"))
            #expect(engineURL.absoluteString.contains("%23"))
            #expect(engineURL.absoluteString.contains("%C3%BC"))
        }
    }

    @Test func encodesASpaceAsPercent20() {
        let url = SearchEngine.bing.searchURL(for: "cats dogs")
        #expect(url.absoluteString == "https://www.bing.com/search?q=cats%20dogs")
    }

    @Test func currentReadsUserDefaults() {
        let defaults = UserDefaults.standard
        let key = SearchEngine.defaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key)
        #expect(SearchEngine.current == .google)
        defaults.set(SearchEngine.kagi.rawValue, forKey: key)
        #expect(SearchEngine.current == .kagi)
        defaults.set("nope", forKey: key)
        #expect(SearchEngine.current == .google)
    }
}
