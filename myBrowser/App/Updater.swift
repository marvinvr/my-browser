import Sparkle

/// Sparkle 2 updater owned by `AppDelegate`.
///
/// Daily automatic checks come from Info.plist (`SUEnableAutomaticChecks`,
/// `SUScheduledCheckInterval`). The app menu calls `checkForUpdates()`.
@MainActor
final class Updater {
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }
}
