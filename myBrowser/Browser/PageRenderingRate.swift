import WebKit

/// Lets page rendering follow the display instead of WebKit's near-60fps cap.
///
/// `PreferPageRenderingUpdatesNear60FPSEnabled` (Safari's "Prefer Page Rendering Updates near 60fps")
/// defaults on and holds `requestAnimationFrame`, CSS animations, and page rendering updates near 60fps.
/// There is no public switch. The private feature list is the one Safari's Feature Flags use.
enum PageRenderingRate {
    static let near60FPSKey = "PreferPageRenderingUpdatesNear60FPSEnabled"

    /// Scrolling already runs off the main thread. These default on; applying the page-rate change must leave them on.
    static let scrollingKeys = [
        "ThreadedScrollingEnabled",
        "AsyncFrameScrollingEnabled",
        "AsyncOverflowScrollingEnabled",
    ]

    /// Call before a web view owns `preferences`. WebKit reads the flag when the view is created.
    static func apply(to preferences: WKPreferences) {
        guard let feature = features[near60FPSKey] else { return }
        set(false, feature, on: preferences)
    }

    /// `nil` when this WebKit has no such feature. `true` is the cap.
    static func prefersUpdatesNear60FPS(_ preferences: WKPreferences) -> Bool? {
        isEnabled(near60FPSKey, on: preferences)
    }

    static func isEnabled(_ key: String, on preferences: WKPreferences) -> Bool? {
        guard let feature = features[key] else { return nil }
        return isEnabled(feature, on: preferences)
    }

    private static let features: [String: NSObject] = {
        let selector = NSSelectorFromString("_features")
        let type: AnyObject = WKPreferences.self
        guard type.responds(to: selector),
              let all = type.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [:] }
        var indexed: [String: NSObject] = [:]
        for feature in all {
            guard let key = feature.value(forKey: "key") as? String else { continue }
            indexed[key] = feature
        }
        return indexed
    }()

    private static let enabledGetter = NSSelectorFromString("_isEnabledForFeature:")
    private static let enabledSetter = NSSelectorFromString("_setEnabled:forFeature:")

    private static func isEnabled(_ feature: NSObject, on preferences: WKPreferences) -> Bool? {
        guard preferences.responds(to: enabledGetter) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let getter = unsafeBitCast(preferences.method(for: enabledGetter), to: Getter.self)
        return getter(preferences, enabledGetter, feature)
    }

    private static func set(_ enabled: Bool, _ feature: NSObject, on preferences: WKPreferences) {
        guard preferences.responds(to: enabledSetter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let setter = unsafeBitCast(preferences.method(for: enabledSetter), to: Setter.self)
        setter(preferences, enabledSetter, enabled, feature)
    }
}
