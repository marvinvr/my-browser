import Foundation
import Testing
@testable import myBrowser

@MainActor
struct URLInputTests {
    @Test func trimsAndResolvesExplicitSchemes() {
        expect("https://example.com/a", url: "https://example.com/a")
        expect("  https://example.com/a  ", url: "https://example.com/a")
        expect("HTTP://Example.COM/Path", url: "http://example.com/Path")
        expect("https://localhost/x", url: "https://localhost/x")
        expect("http://192.168.1.1:8080/a", url: "http://192.168.1.1:8080/a")
        expect("http://[::1]:8080/x", url: "http://[::1]:8080/x")
        expect("file:///tmp/x", url: "file:///tmp/x")
        expect("about:blank", url: "about:blank")
        expect("mailto:a@b.com", url: "mailto:a@b.com")
        expect("MailTo:a@b.com", url: "mailto:a@b.com")
        expect("data:text/plain,hi", url: "data:text/plain,hi")
        expect("ftp://files.example.com/a", url: "ftp://files.example.com/a")
        expect("custom://host/path", url: "custom://host/path")
        expect("javascript:void(0)", url: "javascript:void(0)")
        expect("https://example.com./path?q=1#f", url: "https://example.com/path?q=1#f")
        expect("http://user:pass@example.com/a", url: "http://user:pass@example.com/a")
    }

    @Test func localhostAndIPAddressesAreHTTP() {
        expect("localhost", url: "http://localhost")
        expect("LOCALHOST", url: "http://localhost")
        expect("localhost.", url: "http://localhost")
        expect("localhost:3000/x", url: "http://localhost:3000/x")
        expect("localhost/x", url: "http://localhost/x")
        expect("127.0.0.1", url: "http://127.0.0.1")
        expect("192.168.1.1:8080", url: "http://192.168.1.1:8080")
        expect("192.168.1.1:8080/a?q=1", url: "http://192.168.1.1:8080/a?q=1")
        expect("8.8.8.8", url: "http://8.8.8.8")
        expect("[::1]", url: "http://[::1]")
        expect("[::1]/x", url: "http://[::1]/x")
        expect("[::1]:8080/x", url: "http://[::1]:8080/x")
        expect("[2001:db8::1]", url: "http://[2001:db8::1]")
        expect("[::ffff:192.0.2.1]", url: "http://[::ffff:192.0.2.1]")
        expect("[1:2:3:4:5:6:7:8]", url: "http://[1:2:3:4:5:6:7:8]")
    }

    @Test func domainsAreHTTPS() {
        expect("example.com", url: "https://example.com")
        expect("Example.COM", url: "https://example.com")
        expect("example.com/path?q=1", url: "https://example.com/path?q=1")
        expect("example.com/path?q=a+b#s", url: "https://example.com/path?q=a+b#s")
        expect("example.com.", url: "https://example.com")
        expect("example.com./a", url: "https://example.com/a")
        expect("foo.bar", url: "https://foo.bar")
        expect("my-site.co.uk/a", url: "https://my-site.co.uk/a")
        expect("example.xn--fiqs8s", url: "https://example.xn--fiqs8s")
        expect("  example.com/path?q=1  ", url: "https://example.com/path?q=1")
    }

    @Test func internationalizedDomains() {
        expectHost("münchen.de", scheme: "https", hosts: ["münchen.de", "xn--mnchen-3ya.de"])
        expectHost("münchen.de/pfad", scheme: "https", hosts: ["münchen.de", "xn--mnchen-3ya.de"])
        expectHost("日本.jp", scheme: "https", hosts: ["日本.jp", "xn--wgv71a.jp"])
        expectHost("https://münchen.de/path", scheme: "https", hosts: ["münchen.de", "xn--mnchen-3ya.de"])
    }

    @Test func unicodePathIsPercentEncoded() {
        guard case .url(let url) = URLInput.resolve("example.com/ü") else {
            Issue.record("expected a URL")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.path == "/ü" || url.path == "/%C3%BC")
        #expect(url.absoluteString.contains("%C3%BC") || url.absoluteString.contains("/ü"))
    }

    @Test func searchesInsteadOfNavigating() {
        expectSearch("", "")
        expectSearch("   ", "")
        expectSearch("hello world", "hello world")
        expectSearch("  hello world  ", "hello world")
        expectSearch("google", "google")
        expectSearch("?foo", "?foo")
        expectSearch("#anchor", "#anchor")
        expectSearch("example.com/foo bar", "example.com/foo bar")
        expectSearch("http://example.com/foo bar", "http://example.com/foo bar")
        expectSearch("a.b", "a.b")
        expectSearch("example.", "example.")
        expectSearch("256.1.1.1", "256.1.1.1")
        expectSearch("192.168.1", "192.168.1")
        expectSearch("example.com:99999", "example.com:99999")
        expectSearch("example.com:", "example.com:")
        expectSearch("example.com:abc", "example.com:abc")
        expectSearch("[::1]:99999", "[::1]:99999")
        expectSearch("[::1", "[::1")
        expectSearch("[gggg::1]", "[gggg::1]")
        expectSearch("::1", "::1")
        expectSearch("not a url", "not a url")
        expectSearch(".com", ".com")
        expectSearch("example..com", "example..com")
        expectSearch("-bad.com", "-bad.com")
        expectSearch("user@example.com", "user@example.com")
    }

    @Test func urlForUsesTheEngineForSearches() {
        let search = URLInput.url(for: "cats & dogs", engine: .kagi)
        #expect(search == SearchEngine.kagi.searchURL(for: "cats & dogs"))
        let direct = URLInput.url(for: "example.com/a", engine: .bing)
        #expect(direct.absoluteString == "https://example.com/a")
    }

    @Test func relaxedHostsAreHTTP() {
        expect("photos/", url: "http://photos/")
        expect("Photos/albums", url: "http://photos/albums")
        expect("meals/", url: "http://meals/")
        expect("coolify:8000", url: "http://coolify:8000")
        expect("coolify:8000/x", url: "http://coolify:8000/x")
        expect("COOLIFY:8000/", url: "http://coolify:8000/")
        expect("nas.local", url: "http://nas.local")
        expect("nas.local/a", url: "http://nas.local/a")
        expect("box.ts.net", url: "http://box.ts.net")
        expect("a.b.ts.net/x", url: "http://a.b.ts.net/x")
        expect("printer.internal", url: "http://printer.internal")
        expect("dev.lan/x", url: "http://dev.lan/x")
        expect("printer.home.arpa", url: "http://printer.home.arpa")
        expect("foo.bar.home.arpa/a", url: "http://foo.bar.home.arpa/a")
        expect("example.com:8080/x", url: "http://example.com:8080/x")
        expect("http://photos/", url: "http://photos/")
        expect("https://photos/", url: "https://photos/")
        expect("http://example.com/a", url: "http://example.com/a")
        expect("https://example.com/a", url: "https://example.com/a")
    }

    @Test func bareSingleLabelNavigatesOnlyWhenItResolves() {
        expect("photos", url: "http://photos/", bareHostResolves: { $0 == "photos" })
        expect("Photos", url: "http://photos/", bareHostResolves: { $0 == "photos" })
        expect("photos.", url: "http://photos/", bareHostResolves: { $0 == "photos" })
        expectSearch("photos", "photos", bareHostResolves: { _ in false })
        expectSearch("meals", "meals", bareHostResolves: { $0 == "photos" })
        expectSearch("google", "google", bareHostResolves: { _ in false })
        #expect(URLInput.bareHostCandidate("photos") == "photos")
        #expect(URLInput.bareHostCandidate("photos/") == nil)
        #expect(URLInput.bareHostCandidate("hello world") == nil)
    }

    @Test func httpsFirstIsOnlySynthesizedPublicHTTPS() {
        #expect(URLInput.isHTTPSFirst("example.com"))
        #expect(URLInput.isHTTPSFirst("example.com/a"))
        #expect(!URLInput.isHTTPSFirst("https://example.com"))
        #expect(!URLInput.isHTTPSFirst("HTTPS://example.com/a"))
        #expect(!URLInput.isHTTPSFirst("http://example.com"))
        #expect(!URLInput.isHTTPSFirst("photos/"))
        #expect(!URLInput.isHTTPSFirst("coolify:8000"))
        #expect(!URLInput.isHTTPSFirst("example.com:8080"))
        #expect(!URLInput.isHTTPSFirst("nas.local"))
        #expect(!URLInput.isHTTPSFirst("box.ts.net"))
        #expect(!URLInput.isHTTPSFirst("google"))
        #expect(!URLInput.isHTTPSFirst("http://photos/"))
    }

    private func expect(
        _ input: String,
        url expected: String,
        bareHostResolves: (String) -> Bool = { _ in false },
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch URLInput.resolve(input, bareHostResolves: bareHostResolves) {
        case .url(let url):
            #expect(url.absoluteString == expected, "resolve(\(input))", sourceLocation: sourceLocation)
        case .search(let query):
            Issue.record("expected \(expected), got search \(query.debugDescription)", sourceLocation: sourceLocation)
        }
    }

    private func expectSearch(
        _ input: String,
        _ expected: String,
        bareHostResolves: (String) -> Bool = { _ in false },
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch URLInput.resolve(input, bareHostResolves: bareHostResolves) {
        case .search(let query):
            #expect(query == expected, "resolve(\(input))", sourceLocation: sourceLocation)
        case .url(let url):
            Issue.record("expected search \(expected.debugDescription), got \(url.absoluteString)", sourceLocation: sourceLocation)
        }
    }

    private func expectHost(
        _ input: String,
        scheme: String,
        hosts: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .url(let url) = URLInput.resolve(input) else {
            Issue.record("expected a URL for \(input)", sourceLocation: sourceLocation)
            return
        }
        #expect(url.scheme == scheme, sourceLocation: sourceLocation)
        let host = url.host ?? ""
        #expect(hosts.contains(host), "host \(host) not in \(hosts)", sourceLocation: sourceLocation)
    }
}
