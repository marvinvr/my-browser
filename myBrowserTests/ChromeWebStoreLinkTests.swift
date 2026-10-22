import Foundation
import Testing
@testable import myBrowser

struct ChromeWebStoreLinkTests {
    private let darkReader = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    @Test func readsABareIDAndAStoreURL() {
        #expect(ChromeWebStoreLink.extensionID(in: "  \(darkReader)  ") == darkReader)
        let link = "https://chromewebstore.google.com/detail/dark-reader/\(darkReader)"
        #expect(ChromeWebStoreLink.extensionID(in: link) == darkReader)
        #expect(ChromeWebStoreLink.extensionID(in: "not-an-id") == nil)
        #expect(ChromeWebStoreLink.isExtensionID(String(repeating: "q", count: 32)) == false)
    }

    @Test func downloadURLEncodesTheIDParameter() throws {
        let url = try #require(ChromeWebStoreLink.downloadURL(id: darkReader, chromeVersion: "138.0.7204.100"))
        let absolute = url.absoluteString
        #expect(absolute.hasPrefix("https://clients2.google.com/service/update2/crx?"))
        #expect(absolute.contains("prodversion=138.0.7204.100"))
        #expect(absolute.contains("acceptformat=crx2,crx3") || absolute.contains("acceptformat=crx2%2Ccrx3"))
        #expect(absolute.contains("id%3D\(darkReader)%26uc"))
        #expect(ChromeWebStoreLink.downloadURL(id: "nope") == nil)
    }
}
