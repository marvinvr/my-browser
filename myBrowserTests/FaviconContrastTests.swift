import AppKit
import SwiftUI
import Testing
@testable import myBrowser

@MainActor
struct FaviconContrastTests {
    @Test func blackGlyphInvertsOnADarkBackgroundOnly() {
        let image = icon { _ in
            NSColor(srgbRed: 0.14, green: 0.16, blue: 0.18, alpha: 1).setFill()
            NSRect(x: 8, y: 8, width: 16, height: 16).fill()
        }
        let dark = FaviconContrast.presentation(for: image, colorScheme: .dark)
        let light = FaviconContrast.presentation(for: image, colorScheme: .light)
        #expect(dark.plate == false)
        #expect(dark.image !== image)
        #expect(centerLuminance(dark.image) > 0.75)
        #expect(light.plate == false)
        #expect(light.image === image)
        let again = FaviconContrast.presentation(for: image, colorScheme: .dark)
        #expect(again.image === dark.image)
    }

    @Test func whiteGlyphInvertsOnALightBackgroundOnly() {
        let image = icon { _ in
            NSColor.white.setFill()
            NSRect(x: 10, y: 6, width: 12, height: 20).fill()
        }
        let light = FaviconContrast.presentation(for: image, colorScheme: .light)
        let dark = FaviconContrast.presentation(for: image, colorScheme: .dark)
        #expect(light.plate == false)
        #expect(light.image !== image)
        #expect(centerLuminance(light.image) < 0.2)
        #expect(dark.plate == false)
        #expect(dark.image === image)
    }

    @Test func darkMultiColourInkGetsALightPlate() {
        let image = icon { _ in
            NSColor(srgbRed: 0.45, green: 0.08, blue: 0.08, alpha: 1).setFill()
            NSRect(x: 4, y: 8, width: 12, height: 16).fill()
            NSColor(srgbRed: 0.08, green: 0.12, blue: 0.55, alpha: 1).setFill()
            NSRect(x: 16, y: 8, width: 12, height: 16).fill()
        }
        let dark = FaviconContrast.presentation(for: image, colorScheme: .dark)
        let light = FaviconContrast.presentation(for: image, colorScheme: .light)
        #expect(dark.plate == true)
        #expect(dark.image === image)
        #expect(light.plate == false)
        #expect(light.image === image)
    }

    @Test func lightMultiColourInkGetsADarkPlate() {
        let image = icon { _ in
            NSColor(srgbRed: 0.96, green: 0.9, blue: 0.7, alpha: 1).setFill()
            NSRect(x: 4, y: 8, width: 12, height: 16).fill()
            NSColor(srgbRed: 0.82, green: 0.9, blue: 0.98, alpha: 1).setFill()
            NSRect(x: 16, y: 8, width: 12, height: 16).fill()
        }
        #expect(FaviconContrast.presentation(for: image, colorScheme: .light).plate == true)
        #expect(FaviconContrast.presentation(for: image, colorScheme: .dark).plate == false)
    }

    @Test func opaqueArtworkWithItsOwnContrastIsLeftAlone() {
        let image = icon { rect in
            NSColor.black.setFill()
            rect.fill()
            NSColor.white.setFill()
            NSRect(x: 8, y: 4, width: 16, height: 24).fill()
        }
        let dark = FaviconContrast.presentation(for: image, colorScheme: .dark)
        let light = FaviconContrast.presentation(for: image, colorScheme: .light)
        #expect(dark.plate == false)
        #expect(light.plate == false)
        #expect(dark.image === image)
        #expect(light.image === image)
    }

    private func icon(size: Int = 32, draw: (NSRect) -> Void) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4,
            bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: size, height: size)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func centerLuminance(_ image: NSImage) -> CGFloat {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = rep.bitmapData else { return -1 }
        let x = rep.pixelsWide / 2
        let y = rep.pixelsHigh / 2
        let offset = (y * rep.pixelsWide + x) * 4
        let alpha = CGFloat(data[offset + 3]) / 255
        guard alpha > 0.01 else { return 0 }
        let red = min(1, CGFloat(data[offset]) / 255 / alpha)
        let green = min(1, CGFloat(data[offset + 1]) / 255 / alpha)
        let blue = min(1, CGFloat(data[offset + 2]) / 255 / alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
