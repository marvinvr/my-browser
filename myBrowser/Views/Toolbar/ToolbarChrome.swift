import AppKit
import SwiftUI

/// Colours for the address field and navigation controls.
///
/// Pass one into `AddressField` / `NavigationButtons` / `CopyLinkButton` to share a tint.
/// Leave it nil and each control derives the same chrome from the selected tab.
struct ToolbarChrome: Equatable {
    var background: Color
    var field: Color
    var stroke: Color
    var primaryText: Color
    var secondaryText: Color
    var symbol: Color
    var fieldSymbol: Color
    var warning: Color
    var isTinted: Bool

    /// Window background for `colorScheme`, then the page tint when that colour is usable.
    static func resolve(tint: NSColor?, colorScheme: ColorScheme) -> ToolbarChrome {
        let material = windowBackground(for: colorScheme)
        let page = tint.flatMap(components)
        let palette = ToolbarPalette.resolve(tint: page, material: material)
        return ToolbarChrome(palette)
    }

    private init(_ palette: ToolbarPalette.Palette) {
        background = palette.background.color
        field = palette.field.color
        stroke = palette.stroke.color
        primaryText = palette.primaryText.color
        secondaryText = palette.secondaryText.color
        symbol = palette.symbol.color
        fieldSymbol = palette.fieldSymbol.color
        warning = palette.warning.color
        isTinted = palette.isTinted
    }

    private static func windowBackground(for scheme: ColorScheme) -> ToolbarPalette.RGBA {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        var resolved = NSColor(srgbRed: scheme == .dark ? 0.16 : 0.95, green: scheme == .dark ? 0.16 : 0.95, blue: scheme == .dark ? 0.17 : 0.96, alpha: 1)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                resolved = color
            }
        }
        return components(resolved) ?? ToolbarPalette.RGBA(r: resolved.redComponent, g: resolved.greenComponent, b: resolved.blueComponent, a: 1)
    }

    private static func components(_ color: NSColor) -> ToolbarPalette.RGBA? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return ToolbarPalette.RGBA(
            r: Double(srgb.redComponent),
            g: Double(srgb.greenComponent),
            b: Double(srgb.blueComponent),
            a: Double(srgb.alphaComponent)
        )
    }
}

private extension ToolbarPalette.RGBA {
    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
