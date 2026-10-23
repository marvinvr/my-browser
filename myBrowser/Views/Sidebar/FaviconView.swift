import AppKit
import SwiftUI

/// Live favicon, or the host's first letter on a soft color, or a globe.
struct FaviconView: View {
    var image: NSImage?
    var url: URL?
    var title: String
    var size: CGFloat = SidebarMetrics.rowIcon

    @Environment(\.colorScheme) private var colorScheme

    /// Continuous corner, 24% of the box. Applied only to opaque edge-to-edge art.
    private static let cornerFraction: CGFloat = 0.24

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * Self.cornerFraction, style: .continuous)
    }

    var body: some View {
        Group {
            if let image {
                favicon(image)
            } else if let letter = SidebarTitle.monogram(url: url, title: title) {
                Text(letter)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: size, height: size)
                    .background(softColor, in: iconShape)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    /// Scaled to fit and centred. A full-bleed square is the only icon that is clipped.
    /// Anything else keeps its transparent padding, with no fill behind it other than the contrast plate.
    @ViewBuilder
    private func favicon(_ image: NSImage) -> some View {
        let presentation = FaviconContrast.presentation(for: image, colorScheme: colorScheme)
        let content = ZStack {
            if presentation.plate {
                iconShape.fill(plateColor)
            }
            Image(nsImage: presentation.image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
        .frame(width: size, height: size)
        if presentation.roundsCorners {
            content.clipShape(iconShape)
        } else {
            content
        }
    }

    /// Light chip in dark mode, dark chip in light mode. Solid, so vibrancy does not wash it out.
    private var plateColor: Color {
        colorScheme == .dark
            ? Color(red: 0.93, green: 0.93, blue: 0.94)
            : Color(red: 0.22, green: 0.22, blue: 0.24)
    }

    private var softColor: Color {
        let key = SidebarTitle.host(of: url) ?? title
        let palette: [Color] = [.blue, .teal, .purple, .pink, .orange, .green, .indigo, .mint]
        let index = Self.stableHash(key) % palette.count
        return palette[index].opacity(0.38)
    }

    private static func stableHash(_ key: String) -> Int {
        var hash = 5381
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return hash & 0x7fff_ffff
    }
}
