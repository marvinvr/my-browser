import Foundation

nonisolated extension SpaceColor {
    /// Nearest sidebar colour for an sRGB triple. Low saturation maps to gray.
    static func nearest(red: Double, green: Double, blue: Double) -> SpaceColor {
        let red = min(max(red, 0), 1)
        let green = min(max(green, 0), 1)
        let blue = min(max(blue, 0), 1)
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let delta = maxChannel - minChannel
        if maxChannel < 0.08 || delta < 0.08 || delta / maxChannel < 0.18 {
            return .gray
        }

        let hue: Double
        if maxChannel == red {
            hue = (green - blue) / delta
        } else if maxChannel == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        var degrees = hue / 6 * 360
        if degrees < 0 { degrees += 360 }

        switch degrees {
        case ..<15, 345...: return .red
        case 15..<45: return .orange
        case 45..<70: return .yellow
        case 70..<160: return .green
        case 160..<195: return .teal
        case 195..<255: return .blue
        case 255..<295: return .purple
        default: return .pink
        }
    }
}
