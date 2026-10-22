import AppKit
import SwiftUI

/// Grabs the hosting window once attached and applies the borderless full-size titlebar.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.applyWindowStyle()
    }

    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowStyle()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func applyWindowStyle() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            // Sidebar material samples the desktop only when the window itself is clear.
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
