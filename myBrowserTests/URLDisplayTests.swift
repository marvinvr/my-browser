import Foundation
import Testing
@testable import myBrowser

@MainActor
struct URLDisplayTests {
    @Test func nilURLIsEmpty() {
        let display = URLDisplay.format(nil)
        #expect(display.isEmpty)
        #expect(display.plainText == "")
        #expect(display.security == .none)
    }

    @Test func shortHostDropsSchemeAndWWW() {
        let display = format("https://www.github.com")
        #expect(display.plainText == "github.com")
        #expect(display.security == .none)
        #expect(display.pieces.map(\.kind) == [.host])
    }

    @Test func pathSegmentsAreSeparated() {
        let display = format("https://github.com/marvinvr/my-browser")
        #expect(display.plainText == "github.com  /  marvinvr  /  my browser")
        #expect(display.pieces.map(\.kind) == [.host, .separator, .path, .separator, .path])
    }

    @Test func deepPathKeepsTheLastTwoReadableSegments() {
        let display = format("https://github.com/marvinvr/my-browser/tree/main/docs")
        #expect(display.plainText == "github.com  /  main  /  docs")
        #expect(display.pieces.last?.kind == .path)
        #expect(!display.pieces.contains { $0.kind == .ellipsis })
    }

    @Test func queryStringTrackingParamsAndFragmentAreDropped() {
        let display = format("https://www.google.com/search?q=hello+world&utm_source=newsletter&utm_medium=email&fbclid=abc&gclid=def#results")
        #expect(display.plainText == "google.com  /  search")
        #expect(!display.plainText.contains("utm"))
        #expect(!display.plainText.contains("hello"))
        #expect(!display.plainText.contains("fbclid"))
        #expect(!display.plainText.contains("results"))
        #expect(display.absolute.contains("utm_source"))
    }

    @Test func trailingSlashDoesNotAddAnEmptySegment() {
        let display = format("https://example.com/docs/")
        #expect(display.plainText == "example.com  /  docs")
    }

    @Test func localhostKeepsPortAndIsNotInsecure() {
        let withPort = format("http://localhost:3000/docs")
        #expect(withPort.plainText == "localhost:3000  /  docs")
        #expect(withPort.security == .none)

        let plain = format("http://localhost/docs")
        #expect(plain.plainText == "localhost  /  docs")
        #expect(plain.security == .none)

        let loopback = format("http://127.0.0.1:8765/a")
        #expect(loopback.plainText == "127.0.0.1:8765")
        #expect(loopback.security == .none)

        let ipv6 = format("http://[::1]:8080/docs")
        #expect(ipv6.plainText == "[::1]:8080  /  docs")
        #expect(ipv6.security == .none)
    }

    @Test func publicHTTPIsInsecureAndIPStaysLiteral() {
        let page = format("http://neverssl.com")
        #expect(page.plainText == "neverssl.com")
        #expect(page.security == .insecure)

        let ip = format("http://192.168.1.10")
        #expect(ip.plainText == "192.168.1.10")
        #expect(ip.security == .insecure)

        let secureIP = format("https://192.168.1.10/status")
        #expect(secureIP.plainText == "192.168.1.10  /  status")
        #expect(secureIP.security == .none)
    }

    @Test func httpsShowsNoWarningAndDropsDefaultPort() {
        let display = format("https://example.com:443/a")
        #expect(display.plainText == "example.com")
        #expect(display.security == .none)

        let custom = format("https://www.example.com:8443/a")
        #expect(custom.plainText == "example.com:8443")
    }

    @Test func fileURLShowsTheFileName() {
        let display = URLDisplay.format(URL(fileURLWithPath: "/Users/mvr/docs/readme.md"))
        #expect(display.plainText == "readme.md")
        #expect(display.security == .none)
        #expect(display.absolute.hasPrefix("file://"))

        let spaced = URLDisplay.format(URL(fileURLWithPath: "/tmp/My Notes.txt"))
        #expect(spaced.plainText == "My Notes.txt")
    }

    @Test func internationalizedDomainUsesUnicode() {
        let german = format("https://www.xn--mnchen-3ya.de/pfad")
        #expect(german.plainText == "münchen.de  /  pfad")

        let japan = format("https://xn--wgv71a.jp/")
        #expect(japan.plainText == "日本.jp")

        let china = format("https://example.xn--fiqs8s/a")
        #expect(china.plainText == "example.中国")
    }

    @Test func realWorldPathsDropNoise() {
        let cases = [
            ("https://github.com/apple/swift", "github.com  /  apple  /  swift"),
            ("https://github.com/marvinvr/my-browser", "github.com  /  marvinvr  /  my browser"),
            ("https://github.com/apple/swift/blob/main/README.md", "github.com  /  main  /  README.md"),
            ("https://github.com/apple/swift/commit/a1b2c3d4e5f6789012345678abcdef0123456789", "github.com  /  swift  /  commit"),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtube.com  /  watch"),
            ("https://www.google.com/search?q=hello+world&utm_source=newsletter", "google.com  /  search"),
            ("https://dashboard.stripe.com/payments/pi_3MtwBwLkdIwHu7ix28a3tqPa", "dashboard.stripe.com  /  payments"),
            ("https://dashboard.stripe.com/customers/cus_NffrFeUfNV2Hib", "dashboard.stripe.com  /  customers"),
            ("https://dashboard.stripe.com/acct_1A2b3C4d5E6f7G8h/payments", "dashboard.stripe.com  /  payments"),
            ("https://www.notion.so/My-Page-Title-a1b2c3d4e5f64789a0b1c2d3e4f56789", "notion.so  /  My Page Title"),
            ("https://www.notion.so/workspace/Meeting-Notes-abcdef0123456789abcdef0123456789", "notion.so  /  workspace  /  Meeting Notes"),
            ("https://www.amazon.com/Apple-AirPods-Pro/dp/B0CHX7R6WJ", "amazon.com  /  Apple AirPods Pro"),
            ("https://www.amazon.com/dp/B08N5WRWNW", "amazon.com"),
            ("https://accounts.example.com/s/sa/login", "accounts.example.com  /  login"),
            ("https://docs.example.com/v2/guides/getting-started", "docs.example.com  /  guides  /  getting started"),
            ("https://docs.example.com/api/v2.0/users", "docs.example.com  /  api  /  users"),
            ("https://developer.mozilla.org/en-US/docs/Web/API/URL", "developer.mozilla.org  /  API  /  URL"),
            ("https://shop.example.com/account/login.php", "shop.example.com  /  account  /  login"),
            ("https://example.com/docs/index.html", "example.com  /  docs  /  index"),
            ("https://news.ycombinator.com/item?id=38765432", "news.ycombinator.com  /  item"),
            ("https://example.com/a/b/settings", "example.com  /  settings"),
            ("https://app.example.com/orders/550e8400-e29b-41d4-a716-446655440000", "app.example.com  /  orders"),
            ("https://example.com/my%20notes/hello%2Dworld", "example.com  /  my notes  /  hello world"),
            ("https://example.com/en/pricing", "example.com  /  pricing"),
            ("https://example.com/de-ch/products/shoes", "example.com  /  products  /  shoes"),
            ("https://example.com/user/u123456789/profile", "example.com  /  user  /  profile"),
            ("https://cdn.example.com/a/12/ff/9f3a", "cdn.example.com"),
            ("https://example.com/en-US/login", "example.com  /  login"),
        ]
        for (raw, expected) in cases {
            #expect(format(raw).plainText == expected, "\(raw)")
        }
    }

    @Test func noiseStaysInTheRealURL() {
        let raw = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc#t=12"
        let display = format(raw)
        #expect(display.plainText == "youtube.com  /  watch")
        #expect(display.absolute.contains("dQw4w9WgXcQ"))
        #expect(display.absolute.contains("list=PLabc"))
        #expect(!display.plainText.contains("dQw4w9WgXcQ"))
        #expect(!display.plainText.contains("PLabc"))

        let amazon = format("https://www.amazon.com/dp/B08N5WRWNW")
        #expect(amazon.plainText == "amazon.com")
        #expect(amazon.absolute.contains("B08N5WRWNW"))
        #expect(amazon.pieces.map(\.kind) == [.host])
    }

    @Test func veryLongHostAndSegmentAreTruncated() {
        let hostLabel = String(repeating: "a", count: 50)
        let display = format("https://\(hostLabel).example.com/welcome")
        #expect(display.plainText.contains("…"))
        #expect(display.plainText.contains("example.com"))
        #expect(!display.plainText.contains(hostLabel))
        let host = display.pieces.first?.text ?? ""
        #expect(host.count <= URLDisplay.maxHostLength)

        let segment = String(repeating: "b", count: 80)
        let path = format("https://example.com/\(segment)")
        let shown = path.pieces.first { $0.kind == .path }?.text ?? ""
        #expect(shown.contains("…"))
        #expect(shown.count <= URLDisplay.maxSegmentLength)
        #expect(!shown.contains(segment))
    }

    private func format(_ string: String) -> URLDisplay {
        let url = URL(string: string)
        #expect(url != nil)
        return URLDisplay.format(url)
    }
}
