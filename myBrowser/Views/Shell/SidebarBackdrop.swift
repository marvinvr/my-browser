import AppKit
import SwiftUI

/// Behind-window sidebar vibrancy for the whole window, tinted a little with the space color.
struct SidebarBackdrop: View {
    var tint: Color?

    var body: some View {
        ZStack {
            SidebarMaterial()
            (tint ?? .clear).opacity(SidebarMetrics.spaceTintOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> PassThroughVisualEffectView {
        let view = PassThroughVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: PassThroughVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

/// Clicks pass through to the window (traffic lights, dragging) and the views above.
private final class PassThroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
