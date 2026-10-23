import AppKit
import SwiftUI
import WebKit

/// One pane: the tab's web view, a quiet focus treatment, and the hover pill.
struct SplitPaneHost: NSViewRepresentable {
    var tabID: UUID
    var model: BrowserModel
    var focused: Bool
    var split: Bool
    var hovered: Bool
    var vertical: Bool
    var canMovePrevious: Bool
    var canMoveNext: Bool
    var title: String

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitPaneContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> SplitPaneContainer {
        let view = SplitPaneContainer()
        view.pillState = context.coordinator.pill
        return view
    }

    func updateNSView(_ container: SplitPaneContainer, context: Context) {
        container.pillState = context.coordinator.pill
        installWebView(in: container, context: context)
        container.apply(
            split: split,
            focused: focused,
            hovered: hovered,
            title: title
        )
        let pill = context.coordinator.pill
        pill.vertical = vertical
        pill.canMovePrevious = canMovePrevious
        pill.canMoveNext = canMoveNext
        pill.visible = split && hovered
        let tabID = tabID
        let model = model
        pill.onClose = { model.close(tabID) }
        pill.onSeparate = { model.separate(tabID: tabID) }
        pill.onPrevious = {
            guard let index = model.displayedContent?.panes.firstIndex(where: { $0.id == tabID }) else { return }
            model.movePane(tabID: tabID, to: index - 1)
        }
        pill.onNext = {
            guard let index = model.displayedContent?.panes.firstIndex(where: { $0.id == tabID }) else { return }
            model.movePane(tabID: tabID, to: index + 1)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func installWebView(in container: SplitPaneContainer, context: Context) {
        guard let tab = model.tabs[tabID] else {
            container.showWebView(nil)
            return
        }
        let shouldLoad = focused || tab.isLoaded
        if shouldLoad {
            tab.loadIfNeeded(using: model.profiles)
        }
        guard let webView = tab.webView else {
            container.showWebView(nil)
            return
        }
        container.showWebView(webView)
        if context.coordinator.installedID != tabID {
            context.coordinator.installedID = tabID
        }
        tab.restoreHistoryWhenWindowed()
    }

    final class Coordinator {
        var installedID: UUID?
        let pill = PanePillModel()
    }
}

@Observable
final class PanePillModel {
    var visible = false
    var vertical = false
    var canMovePrevious = false
    var canMoveNext = false
    var onClose: () -> Void = {}
    var onSeparate: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
}

/// Glass controls that fade in while the pointer is over the pane.
private struct PanePill: View {
    var state: PanePillModel

    var body: some View {
        HStack(spacing: 1) {
            pillButton(
                state.vertical ? "chevron.up" : "chevron.left",
                help: state.vertical ? "Move Up" : "Move Left",
                enabled: state.canMovePrevious,
                action: state.onPrevious
            )
            pillButton(
                state.vertical ? "chevron.down" : "chevron.right",
                help: state.vertical ? "Move Down" : "Move Right",
                enabled: state.canMoveNext,
                action: state.onNext
            )
            pillButton("arrow.up.right.square", help: "Separate", enabled: true, action: state.onSeparate)
            pillButton("xmark", help: "Close Pane", enabled: true, action: state.onClose)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .glassEffect(.regular, in: Capsule())
        // Hug the controls. A hosting view that takes the pane width keeps them centered.
        .fixedSize()
        .opacity(state.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.16), value: state.visible)
    }

    private func pillButton(
        _ systemName: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .medium))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(enabled ? 1 : 0.28)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

final class SplitPaneContainer: NSView {
    var pillState: PanePillModel?
    private var webView: WKWebView?
    private let dim = SplitPassView()
    private let ring = SplitFocusRing()
    private let placeholder = NSTextField(labelWithString: "")
    private var pillHost: PillHostingView?
    private var split = false
    private var focused = false
    private var hovered = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        dim.translatesAutoresizingMaskIntoConstraints = false
        ring.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 13, weight: .medium)
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.maximumNumberOfLines = 2
        addSubview(placeholder)
        addSubview(dim)
        addSubview(ring)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Frame, not constraints. A flipped container plus edge constraints left the page
    /// shifted and wide enough to cover the gap between panes.
    func showWebView(_ next: WKWebView?) {
        guard webView !== next else {
            placeholder.isHidden = next != nil
            webView?.frame = bounds
            return
        }
        if let webView {
            webView.removeFromSuperview()
        }
        webView = next
        placeholder.isHidden = next != nil
        guard let next else { return }
        next.translatesAutoresizingMaskIntoConstraints = true
        next.clipsToBounds = true
        addSubview(next, positioned: .below, relativeTo: dim)
        next.frame = bounds
    }

    override func layout() {
        super.layout()
        placePill()
        // A fullscreen video's window is not this pane. Resizing it here would pull it back.
        guard let webView, webView.window === window else { return }
        webView.frame = bounds
    }

    func apply(split: Bool, focused: Bool, hovered: Bool, title: String) {
        let changed = self.split != split || self.focused != focused || self.hovered != hovered
        self.split = split
        self.focused = focused
        self.hovered = hovered
        placeholder.stringValue = title.isEmpty ? "Empty pane" : title
        ensurePill()
        pillHost?.passesThrough = !(split && hovered)
        pillHost?.isHidden = !split
        if changed {
            applyChrome(animated: window != nil)
        } else {
            applyChrome(animated: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome(animated: false)
    }

    private func ensurePill() {
        guard pillHost == nil, let pillState else { return }
        let host = PillHostingView(rootView: PanePill(state: pillState))
        // Frame, not constraints. A wide hosting view pinned on its trailing edge
        // still centers the controls in the pane.
        host.translatesAutoresizingMaskIntoConstraints = true
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.required, for: .horizontal)
        host.setContentHuggingPriority(.required, for: .vertical)
        host.passesThrough = true
        addSubview(host)
        pillHost = host
        placePill()
    }

    /// Top trailing corner, inset 6pt. The container is flipped, so y grows downward.
    private func placePill() {
        guard let pillHost, bounds.width > 1, bounds.height > 1 else { return }
        pillHost.layoutSubtreeIfNeeded()
        var size = pillHost.fittingSize
        if size.width < 8 || size.height < 8 || size.width > 160 {
            let intrinsic = pillHost.intrinsicContentSize
            if intrinsic.width >= 8, intrinsic.width <= 160 { size = intrinsic }
        }
        let width = min(max(size.width, 8), min(160, bounds.width - 12))
        let height = min(max(size.height, 8), min(40, bounds.height - 12))
        pillHost.frame = CGRect(x: bounds.maxX - width - 6, y: 6, width: width, height: height)
    }

    private func applyChrome(animated: Bool) {
        let radius: CGFloat = split ? SplitMetrics.cornerRadius : 0
        layer?.cornerRadius = radius
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        ring.radius = max(2, radius - 1)
        ring.active = split && focused
        ring.needsDisplay = true
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dimmed: CGFloat = split && !focused ? (dark ? 0.16 : 0.05) : 0
        let updates = {
            self.dim.alphaValue = dimmed
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                updates()
            }
        } else {
            updates()
        }
    }
}

/// Draws nothing that can be clicked. Sits above the page so the dim and the ring stay visible.
private final class SplitPassView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SplitFocusRing: NSView {
    var active = false
    var radius: CGFloat = 7

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard active else { return }
        let rect = bounds.insetBy(dx: 1.25, dy: 1.25)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.controlAccentColor.withAlphaComponent(0.92).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

private final class PillHostingView: NSHostingView<PanePill> {
    var passesThrough = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !passesThrough else { return nil }
        return super.hitTest(point)
    }
}
