import AppKit
import SwiftUI

/// Live favicon, or the host's first letter on a soft color, or a globe.
struct FaviconView: View {
    var image: NSImage?
    var url: URL?
    var title: String
    var size: CGFloat = SidebarMetrics.rowIcon

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.18), style: .continuous))
            } else if let letter = SidebarTitle.monogram(url: url, title: title) {
                Text(letter)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: size, height: size)
                    .background(softColor, in: RoundedRectangle(cornerRadius: max(3, size * 0.22), style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.78))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
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
