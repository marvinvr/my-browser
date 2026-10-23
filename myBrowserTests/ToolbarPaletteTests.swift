import Testing
@testable import myBrowser

@MainActor
struct ToolbarPaletteTests {
    private let lightWindow = ToolbarPalette.RGBA(r: 0.95, g: 0.95, b: 0.96, a: 1)
    private let darkWindow = ToolbarPalette.RGBA(r: 0.12, g: 0.12, b: 0.13, a: 1)

    @Test func materialTextAndEdgeClearContrast() {
        assertLegible(ToolbarPalette.resolve(tint: nil, material: lightWindow), lightText: false)
        assertLegible(ToolbarPalette.resolve(tint: nil, material: darkWindow), lightText: true)
    }

    @Test func darkPageTintStaysOnTheMaterial() {
        let github = ToolbarPalette.RGBA(r: 13 / 255, g: 17 / 255, b: 23 / 255, a: 1)
        let palette = ToolbarPalette.resolve(tint: github, material: lightWindow)
        #expect(palette.isTinted)
        assertCalm(palette, material: lightWindow, lightText: false)
    }

    @Test func lightPageTintStaysOnTheDarkMaterial() {
        let palette = ToolbarPalette.resolve(tint: .white, material: darkWindow)
        #expect(palette.isTinted)
        assertCalm(palette, material: darkWindow, lightText: true)
    }

    @Test func strongBrandColorIsAQuietWash() {
        // Stripe-like blurple. Saturated, but not a pure neon primary.
        let blurple = ToolbarPalette.RGBA(r: 0.388, g: 0.357, b: 1, a: 1)
        #expect(ToolbarPalette.isUsable(blurple))
        let palette = ToolbarPalette.resolve(tint: blurple, material: lightWindow)
        #expect(palette.isTinted)
        assertCalm(palette, material: lightWindow, lightText: false)
    }

    @Test func brightPageDoesNotPaintAStripe() {
        let yellow = ToolbarPalette.RGBA(r: 1, g: 0.86, b: 0.1, a: 1)
        let red = ToolbarPalette.RGBA(r: 0.86, g: 0.12, b: 0.12, a: 1)
        #expect(ToolbarPalette.isUsable(yellow))
        #expect(ToolbarPalette.isUsable(red))
        for tint in [yellow, red] {
            let palette = ToolbarPalette.resolve(tint: tint, material: lightWindow)
            #expect(palette.isTinted)
            assertCalm(palette, material: lightWindow, lightText: false)
            let dark = ToolbarPalette.resolve(tint: tint, material: darkWindow)
            #expect(dark.isTinted)
            assertCalm(dark, material: darkWindow, lightText: true)
        }
    }

    @Test func transparentAndNeonFallBackToMaterial() {
        let clear = ToolbarPalette.RGBA(r: 1, g: 0, b: 0, a: 0)
        let faint = ToolbarPalette.RGBA(r: 0, g: 0, b: 0, a: 0.1)
        let neon = ToolbarPalette.RGBA(r: 0, g: 1, b: 0, a: 1)
        let pureRed = ToolbarPalette.RGBA(r: 1, g: 0, b: 0, a: 1)
        #expect(!ToolbarPalette.isUsable(clear))
        #expect(!ToolbarPalette.isUsable(faint))
        #expect(!ToolbarPalette.isUsable(neon))
        #expect(!ToolbarPalette.isUsable(pureRed))

        let palette = ToolbarPalette.resolve(tint: neon, material: darkWindow)
        #expect(!palette.isTinted)
        #expect(palette.background == ToolbarPalette.resolve(tint: nil, material: darkWindow).background)
    }

    /// The wash may carry a little hue. It must not jump away from the window in brightness.
    private func assertCalm(_ palette: ToolbarPalette.Palette, material: ToolbarPalette.RGBA, lightText: Bool) {
        #expect(abs(palette.background.relativeLuminance - material.relativeLuminance) <= 0.05)
        let channels = [palette.background.r, palette.background.g, palette.background.b]
        let chroma = (channels.max() ?? 0) - (channels.min() ?? 0)
        #expect(chroma <= 0.08)
        assertLegible(palette, lightText: lightText)
    }

    private func assertLegible(_ palette: ToolbarPalette.Palette, lightText: Bool) {
        #expect(ToolbarPalette.contrast(palette.primaryText, palette.field) >= 4.5)
        #expect(ToolbarPalette.contrast(palette.secondaryText, palette.field) >= 3)
        #expect(ToolbarPalette.contrast(palette.symbol, palette.background) >= 4.5)
        #expect(ToolbarPalette.contrast(palette.fieldSymbol, palette.field) >= 4.5)
        #expect(ToolbarPalette.contrast(palette.stroke, palette.background) >= 3)
        if lightText {
            #expect(palette.primaryText.relativeLuminance > 0.5)
        } else {
            #expect(palette.primaryText.relativeLuminance < 0.2)
        }
    }
}
