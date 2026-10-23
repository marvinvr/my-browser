import Foundation
import Testing
@testable import myBrowser

@MainActor
struct NotificationPermissionStoreTests {
    @Test func originDropsDefaultPortsAndRejectsNonWeb() {
        #expect(NotificationOrigin.key(for: URL(string: "https://Example.com/path")!) == "https://example.com")
        #expect(NotificationOrigin.key(for: URL(string: "https://example.com:443/")!) == "https://example.com")
        #expect(NotificationOrigin.key(for: URL(string: "http://example.com:80/a")!) == "http://example.com")
        #expect(NotificationOrigin.key(for: URL(string: "https://example.com:8443/a")!) == "https://example.com:8443")
        #expect(NotificationOrigin.key(for: URL(string: "https://example.com./")!) == "https://example.com")
        #expect(NotificationOrigin.key(for: URL(string: "file:///tmp/page.html")!) == nil)
        #expect(NotificationOrigin.key(scheme: "javascript", host: "example.com", port: 0) == nil)
        #expect(NotificationOrigin.isKey("https://example.com"))
        #expect(!NotificationOrigin.isKey("https://example.com/"))
        #expect(!NotificationOrigin.isKey("https://Example.com"))
    }

    @Test func displayHostStripsWWWAndKeepsCustomPort() {
        #expect(NotificationOrigin.displayHost("https://www.mail.google.com") == "mail.google.com")
        #expect(NotificationOrigin.displayHost("https://example.com:8443") == "example.com:8443")
    }

    @Test func tagReusesOneIdentifierAndAnEmptyTagDoesNot() {
        let profile = UUID()
        let origin = "https://example.com"
        let first = NotificationOrigin.systemIdentifier(profileID: profile, origin: origin, tag: "inbox", noteID: "a")
        let second = NotificationOrigin.systemIdentifier(profileID: profile, origin: origin, tag: "inbox", noteID: "b")
        #expect(first == second)
        let looseA = NotificationOrigin.systemIdentifier(profileID: profile, origin: origin, tag: "", noteID: "a")
        let looseB = NotificationOrigin.systemIdentifier(profileID: profile, origin: origin, tag: "", noteID: "b")
        #expect(looseA != looseB)
        #expect(first.hasPrefix("mb|"))
    }

    @Test func decisionsStayPerProfileAndReplaceInPlace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mb-notifications-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotificationPermissionStore(directory: directory)
        let profile = UUID()
        let other = UUID()
        store.set(profileID: profile, origin: "not a url", decision: .granted)
        #expect(store.records.isEmpty)
        store.set(profileID: profile, origin: "https://example.com", decision: .granted)
        store.set(profileID: profile, origin: "https://example.com", decision: .denied)
        store.set(profileID: other, origin: "https://example.com", decision: .granted)
        #expect(store.records.count == 2)
        #expect(store.decision(profileID: profile, origin: "https://example.com") == .denied)
        #expect(store.decision(profileID: other, origin: "https://example.com") == .granted)
        #expect(store.decisions(for: profile)["https://example.com"] == "denied")
        store.remove(profileID: profile, origin: "https://example.com")
        #expect(store.decision(profileID: profile, origin: "https://example.com") == nil)
        #expect(store.listed.map(\.profileID) == [other])

        let reloaded = NotificationPermissionStore(directory: directory)
        #expect(reloaded.decision(profileID: other, origin: "https://example.com") == .granted)
        #expect(reloaded.decision(profileID: profile, origin: "https://example.com") == nil)
    }

    @Test func scriptEmbedsDecisionsAndDropsTheToken() {
        let source = WebNotificationScript.source(decisions: ["https://example.com": "granted"])
        #expect(source.contains("\"https:\\/\\/example.com\":\"granted\""))
        #expect(!source.contains("__MB_DECISIONS__"))
        #expect(source.contains(WebNotificationScript.marker))
        #expect(source.contains("requestPermission"))
        #expect(source.contains("showNotification"))
        let update = WebNotificationScript.permissionUpdate("granted")
        #expect(update.contains("\"granted\""))
        #expect(!update.contains("\n"))
    }
}
