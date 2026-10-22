import AppKit

/// Light or dark Dock icon. The bundle icon stays the light set.
/// Stored in UserDefaults under `defaultsKey`.
nonisolated enum AppIconVariant: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark

    static let defaultsKey = "appIconVariant"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light (default)"
        case .dark: "Dark"
        }
    }

    /// The user's choice, light when unset or unknown.
    static var current: AppIconVariant {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppIconVariant.init(rawValue:)) ?? .light
    }
}

/// Puts the chosen icon in the Dock for this launch.
///
/// `NSWorkspace.setIcon` is intentionally not used: it rewrites the app bundle,
/// which breaks the code signature and Sparkle updates. `nil` restores the
/// asset-catalog icon.
enum AppIconApplier {
    static func apply(_ variant: AppIconVariant = .current) {
        switch variant {
        case .light:
            NSApp.applicationIconImage = nil
        case .dark:
            NSApp.applicationIconImage = darkDockImage()
        }
        #if DEBUG
        exportAppliedIconIfRequested()
        #endif
    }

    #if DEBUG
    /// `MYBROWSER_DEBUG_ICON_EXPORT` is an absolute PNG path. Writes the Dock image,
    /// or the bundle icon when the Dock is still using the default.
    private static func exportAppliedIconIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_ICON_EXPORT"], !path.isEmpty else { return }
        // `applicationIconImage` is nil while the Dock is showing the bundle icon.
        // Read that icon for the snapshot. This does not call `setIcon`.
        let image = NSApp.applicationIconImage
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
    #endif

    /// 128pt image with the 1024px bitmap, so the Dock scales a sharp icon
    /// instead of treating the asset as a 1024pt picture.
    private static func darkDockImage() -> NSImage? {
        guard let source = NSImage(named: "AppIconDark") else { return nil }
        let points = NSSize(width: 128, height: 128)
        guard let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            source.isTemplate = false
            return source
        }
        rep.size = points
        let image = NSImage(size: points)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }
}
