import WebKit

/// One persistent `WKWebsiteDataStore` per profile, and web view configurations built from it.
final class ProfileManager {
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    /// Per-profile extension controller. Set before the first web view is created.
    var extensionController: ((UUID) -> WKWebExtensionController?)?

    func dataStore(for profileID: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[profileID] { return store }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        dataStores[profileID] = store
        return store
    }

    /// A fresh configuration sharing the profile's data store. Create one per web view;
    /// WebKit does not allow a configuration to be mutated after a web view owns it.
    func configuration(for profileID: UUID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: profileID)
        configuration.preferences.isElementFullscreenEnabled = true
        // AirPlay defaults to allowed; set it explicitly so a future default change can't turn it off.
        // Picture-in-Picture has no macOS configuration flag (the iOS property is unavailable here) and stays at the system default, which allows it.
        configuration.allowsAirPlayForMediaPlayback = true
        // Private preference. Turning it on is what makes the Develop menu / Web Inspector available.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Appended to WebKit's default UA so sites see a Safari-shaped token instead of a bare WebKit shell.
        configuration.applicationNameForUserAgent = Self.safariApplicationName
        if let controller = extensionController?(profileID) {
            configuration.webExtensionController = controller
        }
        return configuration
    }

    /// Safari-like application token for macOS 26. `applicationNameForUserAgent` is appended to the stock WebKit UA.
    static let safariApplicationName = "Version/26.0 Safari/605.1.15"
}
