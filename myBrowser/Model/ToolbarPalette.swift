import Foundation

/// Contrast rules for the toolbar. Pure sRGB math.
///
/// A tint is unusable when it is missing, not solid (`alpha` under 0.85, which covers a
/// fully transparent colour), or neon: saturation at least 0.92 and brightness at least 0.78,
/// or a near-pure primary/secondary (channels pegged high or low). Those fall back to `material`.
///
/// A usable page colour does not paint the bar. It becomes a low-saturation wash held close
/// to the window material, so a dark header or a bright brand cannot turn the toolbar into
/// a solid stripe. The sidebar pill's fill still shifts off that bar until label text clears
/// 4.5:1. The stroke is the pill's edge and aims for 3:1 against the bar.
nonisolated enum ToolbarPalette {
    nonisolated struct RGBA: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
        static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
        /// Near-black label. Pure black is harsher than macOS label colour.
        static let ink = RGBA(r: 0.09, g: 0.09, b: 0.10, a: 1)
        static let paper = RGBA(r: 0.97, g: 0.97, b: 0.98, a: 1)

        var relativeLuminance: Double {
            func channel(_ value: Double) -> Double {
                let c = min(1, max(0, value))
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
    }

    nonisolated struct Palette: Equatable, Sendable {
        var background: RGBA
        var field: RGBA
        var stroke: RGBA
        var primaryText: RGBA
        var secondaryText: RGBA
        /// Nav icons, drawn on `background`.
        var symbol: RGBA
        /// Icons inside the field.
        var fieldSymbol: RGBA
        var warning: RGBA
        var isTinted: Bool
    }

    static func isUsable(_ color: RGBA) -> Bool {
        guard color.r.isFinite, color.g.isFinite, color.b.isFinite, color.a.isFinite else { return false }
        guard color.a >= 0.85 else { return false }
        let channels = [color.r, color.g, color.b]
        let maxC = channels.max() ?? 0
        let minC = channels.min() ?? 0
        let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
        if saturation >= 0.92 && maxC >= 0.78 { return false }
        let high = channels.filter { $0 >= 0.9 }.count
        let low = channels.filter { $0 <= 0.12 }.count
        if high + low == 3 && high >= 1 && maxC >= 0.9 && minC <= 0.12 { return false }
        return true
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let lighter = max(a.relativeLuminance, b.relativeLuminance)
        let darker = min(a.relativeLuminance, b.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// `material` is the window background the untinted bar already sits on.
    static func resolve(tint: RGBA?, material: RGBA) -> Palette {
        let usable = tint.flatMap { isUsable($0) ? opaque($0) : nil }
        let base = opaque(material)
        let background = usable.map { calmBackground(page: $0, material: base) } ?? base
        let field = fieldFill(on: background)
        let primary = textColor(on: field)
        return Palette(
            background: background,
            field: field,
            stroke: edgeColor(on: background, toward: field),
            primaryText: primary,
            secondaryText: secondaryText(primary: primary, on: field),
            symbol: textColor(on: background),
            fieldSymbol: primary,
            warning: warningColor(on: field, fallback: primary),
            isTinted: usable != nil
        )
    }

    /// Page hue as a quiet wash on `material`. Brightness stays near the window.
    static func calmBackground(page: RGBA, material: RGBA) -> RGBA {
        let pageWeight = weighted(page)
        let materialWeight = weighted(material)
        let pastel = RGBA(
            r: clamp(materialWeight + (page.r - pageWeight) * 0.9),
            g: clamp(materialWeight + (page.g - pageWeight) * 0.9),
            b: clamp(materialWeight + (page.b - pageWeight) * 0.9),
            a: 1
        )
        var wash = mix(material, pastel, 0.42)
        let delta = wash.relativeLuminance - material.relativeLuminance
        let limit = 0.045
        if abs(delta) > limit {
            wash = mix(material, wash, limit / abs(delta))
        }
        // A yellow or red page is already near the window's brightness, so the luminance
        // cap does not catch it. Pull hue back until the wash is only faintly tinted.
        let chroma = max(wash.r, wash.g, wash.b) - min(wash.r, wash.g, wash.b)
        let chromaLimit = 0.06
        if chroma > chromaLimit {
            wash = mix(material, wash, chromaLimit / chroma)
        }
        return wash
    }

    // MARK: - Derivation

    /// Lighter on a dark toolbar, darker on a light one, pushed until label text clears 4.5:1.
    static func fieldFill(on background: RGBA) -> RGBA {
        let lighten = background.relativeLuminance < 0.5
        if let fill = shiftedFill(background, toward: lighten ? .white : .black) {
            return fill
        }
        if let fill = shiftedFill(background, toward: lighten ? .black : .white) {
            return fill
        }
        return mix(background, lighten ? .white : .black, 0.45)
    }

    static func textColor(on surface: RGBA) -> RGBA {
        let dark = contrast(.ink, surface)
        let light = contrast(.paper, surface)
        if dark >= 4.5 && dark >= light { return .ink }
        if light >= 4.5 { return .paper }
        return light > dark ? .paper : .ink
    }

    private static func shiftedFill(_ background: RGBA, toward target: RGBA) -> RGBA? {
        var amount = 0.12
        var fill = mix(background, target, amount)
        var steps = 0
        while contrast(textColor(on: fill), fill) < 4.5 && amount < 0.96 && steps < 28 {
            amount += 0.04
            fill = mix(background, target, amount)
            steps += 1
        }
        guard contrast(textColor(on: fill), fill) >= 4.5 else { return nil }
        return fill
    }

    /// Edge of the field. At least 3:1 against the toolbar, following the fill's direction.
    private static func edgeColor(on background: RGBA, toward field: RGBA) -> RGBA {
        let target: RGBA = field.relativeLuminance >= background.relativeLuminance ? .white : .black
        var amount = 0.0
        var color = background
        var steps = 0
        while contrast(color, background) < 3 && amount < 1 && steps < 40 {
            amount += 0.025
            color = mix(background, target, amount)
            steps += 1
        }
        if contrast(field, background) >= 3 {
            let rim = mix(background, field, 0.85)
            if contrast(rim, background) >= 3 { return rim }
        }
        return color
    }

    /// Path runs stay secondary but at least ~3:1 on the field.
    private static func secondaryText(primary: RGBA, on field: RGBA) -> RGBA {
        var amount = 0.42
        var color = mix(primary, field, amount)
        var steps = 0
        while contrast(color, field) < 3.1 && amount > 0.04 && steps < 16 {
            amount -= 0.06
            color = mix(primary, field, amount)
            steps += 1
        }
        return color
    }

    private static func warningColor(on field: RGBA, fallback: RGBA) -> RGBA {
        let red = RGBA(r: 0.78, g: 0.22, b: 0.18, a: 1)
        if contrast(red, field) >= 3 { return red }
        let bright = RGBA(r: 1, g: 0.62, b: 0.55, a: 1)
        if contrast(bright, field) >= 3 { return bright }
        return fallback
    }

    private static func weighted(_ color: RGBA) -> Double {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func opaque(_ color: RGBA) -> RGBA {
        RGBA(r: min(1, max(0, color.r)), g: min(1, max(0, color.g)), b: min(1, max(0, color.b)), a: 1)
    }

    private static func mix(_ a: RGBA, _ b: RGBA, _ amount: Double) -> RGBA {
        let t = min(1, max(0, amount))
        return RGBA(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t,
            a: 1
        )
    }
}
