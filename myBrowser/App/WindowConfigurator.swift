import AppKit
import SwiftUI

/// Grabs the hosting window once attached and applies the borderless full-size titlebar.
/// Moves the traffic lights so their vertical centre matches the toolbar, and republishes
/// their geometry. AppKit resets the buttons on resize and when leaving fullscreen, so the
/// position is applied again after those.
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
        private var positionScheduled = false
        /// True while fullscreen is transitioning or active. The system owns the buttons then.
        private var suspendPositioning = false

        private static let observed: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willEnterFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ]

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in Self.observed {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowChanged(_:)),
                    name: name,
                    object: window
                )
            }
            suspendPositioning = window.styleMask.contains(.fullScreen)
            applyWindowStyle()
        }

        override func layout() {
            super.layout()
            applyChrome()
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
            applyChrome()
        }

        @objc private func windowChanged(_ notification: Notification) {
            switch notification.name {
            case NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                 NSWindow.willExitFullScreenNotification:
                suspendPositioning = true
            case NSWindow.didExitFullScreenNotification:
                suspendPositioning = false
            default:
                if window?.styleMask.contains(.fullScreen) == true {
                    suspendPositioning = true
                }
            }
            applyChrome()
        }

        /// Positions the buttons, then measures them. A second pass runs after AppKit's titlebar layout.
        private func applyChrome() {
            positionTrafficLights()
            publishAnchor()
            schedulePosition()
        }

        private func schedulePosition() {
            guard !positionScheduled else { return }
            positionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionScheduled = false
                self.positionTrafficLights()
                self.publishAnchor()
            }
        }

        private func positionTrafficLights() {
            guard !suspendPositioning, let window, let content = window.contentView else { return }
            guard !window.styleMask.contains(.fullScreen), content.bounds.height > 1 else { return }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for kind in kinds {
                guard let button = window.standardWindowButton(kind),
                      let container = button.superview else { continue }
                let current = button.convert(button.bounds, to: nil)
                guard current.height > 1, current.width > 1 else { continue }
                let contentInWindow = content.convert(content.bounds, to: nil)
                let desiredCenter = contentInWindow.maxY - SidebarMetrics.chromeCenterFromTop
                let desiredOriginY = desiredCenter - current.height / 2
                let delta = desiredOriginY - current.minY
                guard abs(delta) > 0.5 else { continue }
                // Flipped containers grow downward, so the window-space delta flips sign.
                let applied = container.isFlipped ? -delta : delta
                var origin = button.frame.origin
                origin.y += applied
                button.setFrameOrigin(origin)
            }
        }

        private func publishAnchor() {
            guard callbackReady, let measured = measuredAnchor() else { return }
            guard abs(measured.clearance - lastClearance) > 0.5
                    || abs(measured.centerFromTop - lastCenter) > 0.5 else { return }
            lastClearance = measured.clearance
            lastCenter = measured.centerFromTop
            let value = measured
            Task { @MainActor [weak self] in
                self?.onAnchor(value)
            }
        }

        private func measuredAnchor() -> TrafficLightAnchor? {
            guard let window,
                  let zoom = window.standardWindowButton(.zoomButton),
                  let content = window.contentView else { return nil }
            let inWindow = zoom.convert(zoom.bounds, to: nil)
            let frame = content.convert(inWindow, from: nil)
            let clearance = max(frame.maxX - content.bounds.minX + 12, SidebarMetrics.minimumTrafficClearance)
            let centerFromTop = content.isFlipped
                ? frame.midY - content.bounds.minY
                : content.bounds.maxY - frame.midY
            guard clearance > 36, clearance < 160, centerFromTop > 8, centerFromTop < 72 else { return nil }
            return TrafficLightAnchor(clearance: clearance, centerFromTop: centerFromTop)
        }
    }
}
