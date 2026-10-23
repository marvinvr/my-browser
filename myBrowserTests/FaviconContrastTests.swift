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
        #expect(dark.roundsCorners == true)
        #expect(light.roundsCorners == true)
        #expect(dark.image === image)
        #expect(light.image === image)
    }

    @Test func transparentPaddingIsNotRoundedAndStaysClear() {
        let image = icon { _ in
            NSColor.black.setFill()
            NSRect(x: 8, y: 8, width: 16, height: 16).fill()
        }
        let presentation = FaviconContrast.presentation(for: image, colorScheme: .light)
        #expect(presentation.roundsCorners == false)
        #expect(presentation.plate == false)
        let rendered = FaviconBitmap.rendered(image, width: 32, height: 32)
        let corner = pixel(rendered!, x: 0, y: 0)
        #expect(corner.a < 5)
        #expect(corner.r < 5)
        #expect(corner.g < 5)
        #expect(corner.b < 5)
        let png = FaviconBitmap.pngData(of: image, width: 32, height: 32)
        let reloaded = NSImage(data: png!)
        let saved = pixel(reloaded!, x: 0, y: 0)
        #expect(saved.a < 5)
    }

    @Test func nonSquareIconIsNotRounded() {
        let image = icon(width: 40, height: 16) { rect in
            NSColor.red.setFill()
            rect.fill()
        }
        #expect(FaviconContrast.presentation(for: image, colorScheme: .light).roundsCorners == false)
    }

    @Test func renderedBitmapIsPremultipliedSRGB() {
        let image = icon { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            rect.fill()
        }
        let rendered = FaviconBitmap.rendered(image, width: 8, height: 8)!
        var proposed = CGRect(origin: .zero, size: rendered.size)
        let cg = rendered.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!
        #expect(cg.alphaInfo == .premultipliedLast)
        #expect(cg.colorSpace?.name == CGColorSpace.sRGB)
        let sample = pixel(rendered, x: 1, y: 1)
        #expect(sample.r > 240)
        #expect(sample.g < 15)
        #expect(sample.b < 15)
        #expect(sample.a > 250)
    }

    private func icon(width: Int = 32, height: Int = 32, draw: (NSRect) -> Void) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: width, height: height)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func pixel(_ image: NSImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return (-1, -1, -1, -1) }
        let bpp = max(1, cg.bitsPerPixel / 8)
        let offset = y * cg.bytesPerRow + x * bpp
        if cg.bitsPerComponent == 16 {
            func channel(_ index: Int) -> Int {
                let start = offset + index * 2
                return (Int(ptr[start]) << 8) | Int(ptr[start + 1])
            }
            return (channel(0) / 256, channel(1) / 256, channel(2) / 256, channel(3) / 256)
        }
        guard bpp >= 4 else { return (Int(ptr[offset]), Int(ptr[offset]), Int(ptr[offset]), 255) }
        return (Int(ptr[offset]), Int(ptr[offset + 1]), Int(ptr[offset + 2]), Int(ptr[offset + 3]))
    }

    private func centerLuminance(_ image: NSImage) -> CGFloat {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return -1 }
        let sample = pixel(image, x: cg.width / 2, y: cg.height / 2)
        let alpha = CGFloat(sample.a) / 255
        guard alpha > 0.01 else { return 0 }
        let red = min(1, CGFloat(sample.r) / 255 / alpha)
        let green = min(1, CGFloat(sample.g) / 255 / alpha)
        let blue = min(1, CGFloat(sample.b) / 255 / alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
