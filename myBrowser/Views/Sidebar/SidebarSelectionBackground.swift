import SwiftUI

/// Flat highlight for sidebar rows and favorite tiles. No glass: a glass pill was taller than the row and hid its contents.
struct SidebarSelectionBackground: View {
    var isSelected: Bool
    var isHovering: Bool
    var isLoaded: Bool
    var cornerRadius: CGFloat = 8
    var baseOpacity: Double = 0
    var loadedOpacity: Double = 0.05

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Shadow is only applied while selected. A shadow on the translucent hover
        // fill rasterizes it and turns a faint wash into a solid gray bar.
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if isSelected, colorScheme == .light {
                shape
                    .fill(fill)
                    .shadow(color: Color.black.opacity(0.07), radius: 1.25, y: 0.5)
            } else {
                shape.fill(fill)
            }
        }
        .animation(SidebarMotion.selection, value: isSelected)
        .animation(SidebarMotion.selection, value: isHovering)
        .animation(SidebarMotion.selection, value: isLoaded)
    }

    private var fill: Color {
        if isSelected {
            // Light: a soft white chip on the gray sidebar. Dark: a slightly lighter chip.
            return colorScheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.72)
        }
        if isHovering {
            // Lighter than the selection, not a dark bar.
            return colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.42)
        }
        return Color.primary.opacity(wash)
    }

    /// Loaded pins keep a whisper of fill. Hover and selection are handled above.
    private var wash: Double {
        if isSelected || isHovering { return 0 }
        if isLoaded { return loadedOpacity }
        return baseOpacity
    }
}
