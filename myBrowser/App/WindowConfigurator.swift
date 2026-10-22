import AppKit
import SwiftUI

/// Grabs the hosting window once attached and applies the borderless full-size titlebar.
/// Publishes traffic-light geometry so the sidebar toolbar can share their line.
struct WindowConfigurator: NSViewRepresentable {
    @Binding var anchor: TrafficLightAnchor

    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.onAnchor = { newValue in
            if anchor != newValue {
                anchor = newValue
            }
        }
        nsView.callbackReady = true
        nsView.applyWindowStyle()
    }

    final class ConfiguratorView: NSView {
        var onAnchor: (TrafficLightAnchor) -> Void = { _ in }
        var callbackReady = false
        private var lastClearance: CGFloat = -1
        private var lastCenter: CGFloat = -1

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowStyle()
        }

        override func layout() {
            super.layout()
            publishAnchor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func applyWindowStyle() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            // Sidebar material samples the desktop only when the window itself is clear.
            window.isOpaque = false
            window.backgroundColor = .clear
            publishAnchor()
        }

        private func publishAnchor() {
            guard callbackReady, let measured = measuredAnchor() else { return }
            guard abs(measured.clearance - lastClearance) > 0.5
                    || abs(measured.centerFromTop - lastCenter) > 0.5 else { return }
            lastClearance = measured.clearance
            lastCenter = measured.centerFromTop
            Task { @MainActor [weak self] in
                self?.onAnchor(measured)
            }
        }

        private func measuredAnchor() -> TrafficLightAnchor? {
            guard let window,
                  let zoom = window.standardWindowButton(.zoomButton),
                  let content = window.contentView else { return nil }
            let inWindow = zoom.convert(zoom.bounds, to: nil)
            let frame = content.convert(inWindow, from: nil)
            let clearance = frame.maxX - content.bounds.minX + 8
            let centerFromTop = content.isFlipped
                ? frame.midY - content.bounds.minY
                : content.bounds.maxY - frame.midY
            guard clearance > 36, clearance < 160, centerFromTop > 8, centerFromTop < 72 else { return nil }
            return TrafficLightAnchor(clearance: clearance, centerFromTop: centerFromTop)
        }
    }
}
