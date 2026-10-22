import WebKit

/// One persistent `WKWebsiteDataStore` per profile, and web view configurations built from it.
final class ProfileManager {
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    func dataStore(for profileID: UUID) -> WKWebsiteDataStore {
        if let store = dataStores[profileID] { return store }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        dataStores[profileID] = store
        return store
    }

    func configuration(for profileID: UUID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: profileID)
        // TODO(worker B): preferences (fullscreen, PiP, developer extras), user agent.
        return configuration
    }
}
