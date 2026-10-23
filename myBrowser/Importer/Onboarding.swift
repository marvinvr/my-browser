import Foundation

/// First launch offers import. An existing `library.json` counts as already finished,
/// so people who installed before this sheet are not asked again.
enum Onboarding {
    static let completedKey = "hasCompletedOnboarding"

    /// Sets the flag when it has never been set. A later launch does not change it,
    /// even after the default space creates `library.json`.
    static func prepareForLaunch(libraryDirectory: URL, defaults: UserDefaults = .standard) {
        if LibraryStore.libraryOverrideIsActive, defaults === UserDefaults.standard {
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"] != nil, defaults === UserDefaults.standard {
            return
        }
        #endif
        guard defaults.object(forKey: completedKey) == nil else { return }
        let library = libraryDirectory.appending(path: "library.json", directoryHint: .notDirectory)
        let exists = FileManager.default.fileExists(atPath: library.path(percentEncoded: false))
        defaults.set(exists, forKey: completedKey)
    }
}
