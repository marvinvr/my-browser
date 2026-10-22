import SwiftUI

/// Rounded wash for hover and loaded rows, and a glass highlight for the selection.
struct SidebarSelectionBackground: View {
    var isSelected: Bool
    var isHovering: Bool
    var isLoaded: Bool
    var namespace: Namespace.ID
    var cornerRadius: CGFloat = 8
    var baseOpacity: Double = 0
    var loadedOpacity: Double = 0.05
    var hoverOpacity: Double = 0.07

    var body: some View {
        ZStack {
            if wash > 0 {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(wash))
            }
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.5))
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                    .glassEffectID(SidebarMetrics.selectionGlassID, in: namespace)
            }
        }
        .animation(SidebarMotion.selection, value: isSelected)
        .animation(SidebarMotion.selection, value: isHovering)
        .animation(SidebarMotion.selection, value: isLoaded)
    }

    private var wash: Double {
        if isSelected { return 0 }
        if isHovering { return hoverOpacity }
        if isLoaded { return loadedOpacity }
        return baseOpacity
    }
}
