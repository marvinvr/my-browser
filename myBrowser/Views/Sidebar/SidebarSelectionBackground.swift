import AppKit
import SwiftUI

/// Flat highlight for sidebar rows and favorite tiles. No glass: a glass pill was taller than the row and hid its contents.
struct SidebarSelectionBackground: View {
    var isSelected: Bool
    var isHovering: Bool
    var isLoaded: Bool
    var cornerRadius: CGFloat = 8
    var baseOpacity: Double = 0
    var loadedOpacity: Double = 0.05

    var body: some View {
        // Drawn in a non-vibrant layer. A SwiftUI white wash over the sidebar material
        // gets boosted into a light grey pill, which hides white text in dark mode.
        FlatFill(color: fillColor, cornerRadius: cornerRadius)
            .allowsHitTesting(false)
            .animation(SidebarMotion.selection, value: isSelected)
            .animation(SidebarMotion.selection, value: isHovering)
            .animation(SidebarMotion.selection, value: isLoaded)
    }

    private var fillColor: NSColor {
        if isSelected {
            // Light: a soft white chip. Dark: white at 12% so the title stays readable.
            return SidebarFill.white(dark: 0.12, light: 0.72)
        }
        if isHovering {
            return SidebarFill.white(dark: 0.07, light: 0.42)
        }
        return NSColor.labelColor.withAlphaComponent(wash)
    }

    /// Loaded pins keep a whisper of fill. Hover and selection are handled above.
    private var wash: Double {
        if isSelected || isHovering { return 0 }
        if isLoaded { return loadedOpacity }
        return baseOpacity
    }
}

/// White wash that follows the drawing appearance. Dark mode stays a subtle lift, not a light grey pill.
enum SidebarFill {
    static func white(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor.white.withAlphaComponent(isDark ? dark : light)
        }
    }
}

/// Rounded rect whose alpha is baked into the layer. `allowsVibrancy` is false so the
/// sidebar material cannot turn a 12% wash into a solid chip.
struct FlatFill: NSViewRepresentable {
    var color: NSColor
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> FlatFillView {
        let view = FlatFillView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: FlatFillView, context: Context) {
        view.cornerRadius = cornerRadius
        view.fill = color
        view.apply()
    }
}

final class FlatFillView: NSView {
    var cornerRadius: CGFloat = 8
    var fill: NSColor = .clear

    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    func apply() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let appearance = effectiveAppearance
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            let resolved = (fill.usingColorSpace(.sRGB) ?? fill)
            resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        }
        layer?.backgroundColor = CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
