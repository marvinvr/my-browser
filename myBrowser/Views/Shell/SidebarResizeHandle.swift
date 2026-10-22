import AppKit
import SwiftUI

/// The 8pt gap between the sidebar and the content card. Dragging it resizes the sidebar.
struct SidebarResizeHandle: View {
    var width: Double
    var onDrag: (CGFloat, Bool) -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(hovering ? 0.2 : 0))
                .frame(width: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(drag)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                NSCursor.resizeLeftRight.set()
            case .ended:
                hovering = false
                NSCursor.arrow.set()
            }
        }
        .accessibilityLabel("Resize sidebar")
        .accessibilityValue("\(Int(width.rounded())) points")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 12 : -12
            onDrag(delta, true)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                NSCursor.resizeLeftRight.set()
                onDrag(value.translation.width, false)
            }
            .onEnded { value in
                onDrag(value.translation.width, true)
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}
