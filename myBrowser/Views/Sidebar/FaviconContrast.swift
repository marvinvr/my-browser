import AppKit
import SwiftUI

/// How a favicon stays readable on the sidebar. The bitmap is measured once and kept on the image.
enum FaviconContrast {
    struct Presentation {
        var image: NSImage
        /// A rounded plate behind ink that is dark on a dark UI, or light on a light UI.
        var plate: Bool
        /// Continuous rounded clip. Only an opaque edge-to-edge square.
        var roundsCorners: Bool
    }

    static func presentation(for image: NSImage, colorScheme: ColorScheme) -> Presentation {
        let measured = measurement(for: image)
        let dark = colorScheme == .dark
        if let luminance = measured.glyphLuminance {
            let invert = dark ? luminance < 0.45 : luminance > 0.78
            if invert, let flipped = measured.inverted {
                return Presentation(image: flipped, plate: false, roundsCorners: false)
            }
            return Presentation(image: image, plate: false, roundsCorners: measured.fullBleed)
        }
        let plate = dark ? measured.needsLightPlate : measured.needsDarkPlate
        return Presentation(image: image, plate: plate, roundsCorners: measured.fullBleed)
    }

    // MARK: Measure

    /// Retained by the source image, so a favicon the store already holds is not measured again.
    private final class Measurement: NSObject {
        /// Mean luminance when the opaque pixels are one gray and the ground is transparent.
        let glyphLuminance: CGFloat?
        /// Dark multi-colour ink. A light plate keeps it visible on a dark sidebar.
        let needsLightPlate: Bool
        /// Light multi-colour ink. A dark plate keeps it visible on a light sidebar.
        let needsDarkPlate: Bool
        /// Opaque pixels touch every edge of a square bitmap.
        let fullBleed: Bool
        let inverted: NSImage?

        init(
            glyphLuminance: CGFloat?,
            needsLightPlate: Bool,
            needsDarkPlate: Bool,
            fullBleed: Bool,
            inverted: NSImage?
        ) {
            self.glyphLuminance = glyphLuminance
            self.needsLightPlate = needsLightPlate
            self.needsDarkPlate = needsDarkPlate
            self.fullBleed = fullBleed
            self.inverted = inverted
        }
    }

    nonisolated(unsafe) private static var measurementKey: UInt8 = 0

    private static func measurement(for image: NSImage) -> Measurement {
        if let cached = objc_getAssociatedObject(image, &measurementKey) as? Measurement {
            return cached
        }
        let measured = measure(image)
        objc_setAssociatedObject(image, &measurementKey, measured, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return measured
    }

    /// Samples at most 64px. Anti-aliased edges stay out of the colour test; they have a low alpha.
    private static func measure(_ image: NSImage) -> Measurement {
        let (width, height) = pixelSize(of: image)
        guard let bytes = FaviconBitmap.bytes(of: image, width: width, height: height) else {
            return Measurement(
                glyphLuminance: nil,
                needsLightPlate: false,
                needsDarkPlate: false,
                fullBleed: false,
                inverted: nil
            )
        }
        let count = width * height
        var transparent = 0
        var dark = 0
        var light = 0
        var high = 0
        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var sumY = 0.0
        let square = width == height && width > 0
        var edgeOpaque = square

        for index in 0..<count {
            let pixel = read(bytes, index: index)
            let x = index % width
            let y = index / width
            if square, x == 0 || y == 0 || x == width - 1 || y == height - 1, pixel.alpha < 0.90 {
                edgeOpaque = false
            }
            if pixel.alpha < 0.12 {
                transparent += 1
                continue
            }
            if pixel.alpha >= 0.4 {
                if pixel.luminance < 0.30 { dark += 1 }
                if pixel.luminance > 0.78 { light += 1 }
            }
            if pixel.alpha >= 0.85 {
                high += 1
                sumR += pixel.red
                sumG += pixel.green
                sumB += pixel.blue
                sumY += pixel.luminance
            }
        }

        let area = Double(max(count, 1))
        let transparentFraction = Double(transparent) / area
        let darkFraction = Double(dark) / area
        let lightFraction = Double(light) / area
        let glyph = glyphLuminance(
            bytes: bytes,
            count: count,
            high: high,
            transparentFraction: transparentFraction,
            sumR: sumR,
            sumG: sumG,
            sumB: sumB,
            sumY: sumY
        )
        let ground = transparentFraction >= 0.08
        let needsLightPlate = glyph == nil && ground && darkFraction >= 0.06 && lightFraction < 0.04
        let needsDarkPlate = glyph == nil && ground && lightFraction >= 0.06 && darkFraction < 0.04
        let inverted = glyph == nil ? nil : invertedImage(bytes: bytes, width: width, height: height)
        return Measurement(
            glyphLuminance: glyph,
            needsLightPlate: needsLightPlate,
            needsDarkPlate: needsDarkPlate,
            fullBleed: edgeOpaque,
            inverted: inverted
        )
    }

    /// One gray, with a transparent ground. A second colour (a white eye, a coloured tile) is not a glyph.
    private static func glyphLuminance(
        bytes: [UInt8],
        count: Int,
        high: Int,
        transparentFraction: Double,
        sumR: Double,
        sumG: Double,
        sumB: Double,
        sumY: Double
    ) -> CGFloat? {
        guard high >= 12, transparentFraction >= 0.08 else { return nil }
        let meanR = sumR / Double(high)
        let meanG = sumG / Double(high)
        let meanB = sumB / Double(high)
        var maxDelta = 0.0
        var maxChroma = 0.0
        for index in 0..<count {
            let pixel = read(bytes, index: index)
            guard pixel.alpha >= 0.85 else { continue }
            let delta = max(abs(pixel.red - meanR), abs(pixel.green - meanG), abs(pixel.blue - meanB))
            let chroma = max(pixel.red, pixel.green, pixel.blue) - min(pixel.red, pixel.green, pixel.blue)
            maxDelta = max(maxDelta, delta)
            maxChroma = max(maxChroma, chroma)
        }
        // Chromatic ink keeps its colour and uses a plate. Invert is only for gray marks.
        guard maxDelta < 0.16, maxChroma < 0.09 else { return nil }
        return CGFloat(sumY / Double(high))
    }

    private struct Sample {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
        var luminance: Double
    }

    /// The context stores premultiplied channels. Straight colour is what the glyph test needs.
    private static func read(_ bytes: [UInt8], index: Int) -> Sample {
        let offset = index * 4
        let alpha = Double(bytes[offset + 3]) / 255
        guard alpha > 0.001 else {
            return Sample(red: 0, green: 0, blue: 0, alpha: 0, luminance: 0)
        }
        let red = min(1, Double(bytes[offset]) / 255 / alpha)
        let green = min(1, Double(bytes[offset + 1]) / 255 / alpha)
        let blue = min(1, Double(bytes[offset + 2]) / 255 / alpha)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return Sample(red: red, green: green, blue: blue, alpha: alpha, luminance: luminance)
    }

    private static func invertedImage(bytes: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let context = FaviconBitmap.context(width: width, height: height),
              let destination = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let count = width * height
        for index in 0..<count {
            let pixel = read(bytes, index: index)
            let offset = index * 4
            if pixel.alpha <= 0.001 {
                destination[offset] = 0
                destination[offset + 1] = 0
                destination[offset + 2] = 0
                destination[offset + 3] = 0
                continue
            }
            let alpha = pixel.alpha
            destination[offset] = UInt8(min(255, (1 - pixel.red) * alpha * 255))
            destination[offset + 1] = UInt8(min(255, (1 - pixel.green) * alpha * 255))
            destination[offset + 2] = UInt8(min(255, (1 - pixel.blue) * alpha * 255))
            destination[offset + 3] = UInt8(min(255, alpha * 255))
        }
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static func pixelSize(of image: NSImage) -> (Int, Int) {
        var width = 0
        var height = 0
        for rep in image.representations where rep.pixelsWide * rep.pixelsHigh > width * height {
            width = rep.pixelsWide
            height = rep.pixelsHigh
        }
        if width <= 0 || height <= 0 {
            width = max(1, Int(image.size.width.rounded()))
            height = max(1, Int(image.size.height.rounded()))
        }
        let cap = 64
        let longest = max(width, height)
        guard longest > cap else { return (width, height) }
        let scale = Double(cap) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

}

/// Premultiplied sRGB bitmap for a favicon. Cleared first. Never opaque, never JPEG.
enum FaviconBitmap {
    static func pixelSize(of image: NSImage, cap: Int) -> (Int, Int) {
        var width = 0
        var height = 0
        for rep in image.representations where rep.pixelsWide * rep.pixelsHigh > width * height {
            width = rep.pixelsWide
            height = rep.pixelsHigh
        }
        if width <= 0 || height <= 0 {
            width = max(1, Int((image.size.width * 2).rounded()))
            height = max(1, Int((image.size.height * 2).rounded()))
        }
        let longest = max(width, height)
        guard longest > cap else { return (max(width, 1), max(height, 1)) }
        let scale = Double(cap) / Double(longest)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    static func draw(_ image: NSImage, in context: CGContext, width: Int, height: Int) {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(rect)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func bytes(of image: NSImage, width: Int, height: Int) -> [UInt8]? {
        guard let context = context(width: width, height: height) else { return nil }
        draw(image, in: context, width: width, height: height)
        guard let data = context.data else { return nil }
        let count = width * height * 4
        let pointer = data.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    static func rendered(_ image: NSImage, width: Int, height: Int) -> NSImage? {
        guard let context = context(width: width, height: height) else { return nil }
        draw(image, in: context, width: width, height: height)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    static func pngData(of image: NSImage, width: Int, height: Int) -> Data? {
        guard let context = context(width: width, height: height) else { return nil }
        draw(image, in: context, width: width, height: height)
        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
