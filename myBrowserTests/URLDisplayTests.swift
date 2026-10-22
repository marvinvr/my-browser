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
        #expect(display.plainText == "github.com  /  marvinvr  /  my-browser")
        #expect(display.pieces.map(\.kind) == [.host, .separator, .path, .separator, .path])
    }

    @Test func deepPathKeepsThreeSegmentsThenEllipsis() {
        let display = format("https://github.com/marvinvr/my-browser/tree/main/docs")
        #expect(display.plainText == "github.com  /  marvinvr  /  my-browser  /  tree  /  …")
        #expect(display.pieces.last?.kind == .ellipsis)
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
        #expect(loopback.plainText == "127.0.0.1:8765  /  a")
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
        #expect(display.plainText == "example.com  /  a")
        #expect(display.security == .none)

        let custom = format("https://www.example.com:8443/a")
        #expect(custom.plainText == "example.com:8443  /  a")
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
        #expect(china.plainText == "example.中国  /  a")
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
