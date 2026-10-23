import WebKit

/// One persistent `WKWebsiteDataStore` per profile, and web view configurations built from it.
final class ProfileManager {
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    /// Per-profile extension controller. Set before the first web view is created.
    var extensionController: ((UUID) -> WKWebExtensionController?)?

    /// Adds compiled content-blocker lists. Set before the first web view is created.
    var prepareConfiguration: ((WKWebViewConfiguration, UUID) -> Void)?

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
        Self.prepare(configuration)
        if let controller = extensionController?(profileID) {
            configuration.webExtensionController = controller
        }
        prepareConfiguration?(configuration, profileID)
        return configuration
    }

    /// Preferences for a configuration no web view owns yet. Popups and extension pages only need
    /// `PageRenderingRate.apply`; this is the full set for a tab the app creates itself.
    static func prepare(_ configuration: WKWebViewConfiguration) {
        // Known-host upgrade would rewrite an explicit http:// and tailnet names. HTTPS-first
        // for public hosts is decided in URLInput and falls back in the navigation delegate.
        configuration.upgradeKnownHostsToHTTPS = false
        configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        configuration.preferences.isElementFullscreenEnabled = true
        // AirPlay defaults to allowed; set it explicitly so a future default change can't turn it off.
        configuration.allowsAirPlayForMediaPlayback = true
        // macOS has no public allowsPictureInPictureMediaPlayback, and the private preference defaults to off.
        PictureInPictureWebKit.enable(configuration.preferences)
        // Private preference. Turning it on is what makes the Develop menu / Web Inspector available.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Appended to WebKit's default UA so sites see a Safari-shaped token instead of a bare WebKit shell.
        configuration.applicationNameForUserAgent = safariApplicationName
        PageRenderingRate.apply(to: configuration.preferences)
    }

    /// Safari-like application token for macOS 26. `applicationNameForUserAgent` is appended to the stock WebKit UA.
    static let safariApplicationName = "Version/26.0 Safari/605.1.15"
}
