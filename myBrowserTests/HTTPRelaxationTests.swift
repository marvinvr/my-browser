import Foundation
import Testing
@testable import myBrowser

struct HTTPRelaxationTests {
    @Test func suffixesAndSingleLabelsAreRelaxed() {
        #expect(relaxed("photos"))
        #expect(relaxed("meals"))
        #expect(relaxed("Photos."))
        #expect(relaxed("localhost"))
        #expect(relaxed("foo.localhost"))
        #expect(relaxed("nas.local"))
        #expect(relaxed("a.b.local"))
        #expect(relaxed("box.ts.net"))
        #expect(relaxed("a.b.ts.net"))
        #expect(relaxed("printer.internal"))
        #expect(relaxed("dev.lan"))
        #expect(relaxed("printer.home.arpa"))
        #expect(relaxed("foo.bar.home.arpa"))
        #expect(!relaxed("notts.net"))
        #expect(!relaxed("example.com"))
        #expect(!relaxed("evilhome.arpa"))
        #expect(!relaxed("food.example"))
    }

    @Test func anExplicitPortIsAlwaysRelaxed() {
        #expect(relaxed("example.com", port: 8080))
        #expect(relaxed("example.com", port: 443))
        #expect(relaxed("8.8.8.8", port: 80))
        #expect(!relaxed("8.8.8.8"))
    }

    @Test func privateAndCGNATIPv4() {
        #expect(relaxed("10.0.0.1"))
        #expect(relaxed("10.255.255.255"))
        #expect(!relaxed("11.0.0.1"))
        #expect(relaxed("172.16.0.1"))
        #expect(relaxed("172.31.255.255"))
        #expect(!relaxed("172.15.255.255"))
        #expect(!relaxed("172.32.0.1"))
        #expect(relaxed("192.168.0.1"))
        #expect(!relaxed("192.169.0.1"))
        #expect(relaxed("100.64.0.1"))
        #expect(relaxed("100.127.255.255"))
        #expect(!relaxed("100.63.255.255"))
        #expect(!relaxed("100.128.0.1"))
        #expect(relaxed("127.0.0.1"))
        #expect(relaxed("127.1.2.3"))
    }

    @Test func privateIPv6() {
        #expect(relaxed("::1"))
        #expect(relaxed("fd00::1"))
        #expect(relaxed("fc00::"))
        #expect(relaxed("fd7a:115c:a1e0::1"))
        #expect(relaxed("fe80::1"))
        #expect(relaxed("febf::1"))
        #expect(!relaxed("fec0::1"))
        #expect(!relaxed("2001:db8::1"))
        #expect(relaxed("::ffff:10.1.2.3"))
        #expect(relaxed("::ffff:192.168.1.1"))
        #expect(!relaxed("::ffff:8.8.8.8"))
    }

    @Test func httpFallbackOnlyForPublicHTTPS() {
        let page = HTTPRelaxation.httpFallback(from: URL(string: "https://example.com/a?q=1#f")!)
        #expect(page?.absoluteString == "http://example.com/a?q=1#f")
        #expect(HTTPRelaxation.httpFallback(from: URL(string: "http://example.com")!) == nil)
        #expect(HTTPRelaxation.httpFallback(from: URL(string: "https://photos/")!) == nil)
        #expect(HTTPRelaxation.httpFallback(from: URL(string: "https://nas.local/a")!) == nil)
        #expect(HTTPRelaxation.httpFallback(from: URL(string: "https://example.com:8443/a")!) == nil)
        #expect(HTTPRelaxation.httpFallback(from: URL(string: "https://10.0.0.1/")!) == nil)
    }

    @Test func retryableFailuresAreConnectionTimeoutAndCertificate() {
        #expect(retryable(NSURLErrorCannotConnectToHost))
        #expect(retryable(NSURLErrorTimedOut))
        #expect(retryable(NSURLErrorNetworkConnectionLost))
        #expect(retryable(NSURLErrorSecureConnectionFailed))
        #expect(retryable(NSURLErrorServerCertificateUntrusted))
        #expect(retryable(NSURLErrorServerCertificateHasBadDate))
        #expect(retryable(NSURLErrorServerCertificateHasUnknownRoot))
        #expect(retryable(NSURLErrorClientCertificateRequired))
        #expect(!retryable(NSURLErrorCancelled))
        #expect(!retryable(NSURLErrorDNSLookupFailed))
        #expect(!retryable(NSURLErrorNotConnectedToInternet))
        let wrapped = NSError(
            domain: "WebKitErrorDomain",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)]
        )
        #expect(HTTPRelaxation.isRetryableHTTPSFailure(wrapped))
    }

    private func relaxed(_ host: String, port: Int? = nil) -> Bool {
        HTTPRelaxation.isRelaxed(host: host, port: port)
    }

    private func retryable(_ code: Int) -> Bool {
        HTTPRelaxation.isRetryableHTTPSFailure(NSError(domain: NSURLErrorDomain, code: code))
    }
}
