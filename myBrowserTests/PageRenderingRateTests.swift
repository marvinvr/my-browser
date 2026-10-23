import Testing
import WebKit
@testable import myBrowser

@MainActor
struct PageRenderingRateTests {
    @Test func profileConfigurationDisablesTheNear60Cap() {
        let configuration = WKWebViewConfiguration()
        #expect(PageRenderingRate.prefersUpdatesNear60FPS(configuration.preferences) == true)
        ProfileManager.prepare(configuration)
        #expect(PageRenderingRate.prefersUpdatesNear60FPS(configuration.preferences) == false)
        for key in PageRenderingRate.scrollingKeys {
            #expect(PageRenderingRate.isEnabled(key, on: configuration.preferences) == true)
        }
    }

    @Test func applyingAgainLeavesScrollingFeaturesOn() {
        let preferences = WKPreferences()
        PageRenderingRate.apply(to: preferences)
        PageRenderingRate.apply(to: preferences)
        #expect(PageRenderingRate.prefersUpdatesNear60FPS(preferences) == false)
        for key in PageRenderingRate.scrollingKeys {
            #expect(PageRenderingRate.isEnabled(key, on: preferences) == true)
        }
    }
}
