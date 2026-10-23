import SwiftUI

/// Back, forward, and reload/stop. Reads `BrowserModel` from the environment.
///
/// While a page loads, the reload arrow itself spins. A load shorter than 150ms does not
/// start the spin. When loading ends the arrow eases to upright. Clicking during a load stops it.
struct NavigationButtons: View {
    var chrome: ToolbarChrome? = nil

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var resolved: ToolbarChrome {
        chrome ?? ToolbarChrome.resolve(tint: model.selectedTab?.themeColor, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolbarIconButton(
                systemName: "chevron.left",
                enabled: model.selectedTab?.canGoBack == true,
                help: "Back",
                symbol: resolved.symbol
            ) {
                model.selectedTab?.goBack()
            }
            ToolbarIconButton(
                systemName: "chevron.right",
                enabled: model.selectedTab?.canGoForward == true,
                help: "Forward",
                symbol: resolved.symbol
            ) {
                model.selectedTab?.goForward()
            }
            ReloadButton(symbol: resolved.symbol)
        }
        .padding(.horizontal, 2)
        .frame(width: SidebarMetrics.toolbarControl * 3 + 4, height: SidebarMetrics.toolbarControl)
    }
}

/// Icon button with a constant frame. The symbol colour is explicit so it stays legible on a tint.
struct ToolbarIconButton: View {
    var systemName: String
    var enabled: Bool = true
    var help: String
    var symbol: Color
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
                .background {
                    Circle().fill(symbol.opacity(hovering && enabled ? 0.16 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(symbol)
        .opacity(enabled ? 1 : 0.38)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The reload arrow spins for the duration of a load, then eases back to upright.
private struct ReloadButton: View {
    var symbol: Color

    @Environment(BrowserModel.self) private var model
    @State private var phase: Phase = .idle
    @State private var pending: Task<Void, Never>?
    @State private var hovering = false

    private var loading: Bool { model.selectedTab?.isLoading == true }
    private var tabID: UUID? { model.selectedTab?.id }
    /// One turn of `arrow.clockwise` while a page is loading.
    private var revolution: TimeInterval { 0.7 }
    /// Square around the 12pt semibold glyph. Same frame at rest and while spinning.
    private static let glyphSide: CGFloat = 18
    /// The ring sits below the symbol bounds centre: baseline alignment, plus the arrowhead above the cap line.
    private static let ringOffset: CGFloat = 1.125
    private var animating: Bool {
        switch phase {
        case .spinning, .settling: true
        case .idle: false
        }
    }

    var body: some View {
        Button(action: activate) {
            TimelineView(.animation(paused: !animating)) { context in
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .imageScale(.medium)
                    .symbolRenderingMode(.monochrome)
                    .alignmentGuide(VerticalAlignment.center) { dimensions in
                        dimensions[VerticalAlignment.center] + Self.ringOffset
                    }
                    .frame(width: Self.glyphSide, height: Self.glyphSide, alignment: .center)
                    .rotationEffect(.degrees(displayedAngle(at: context.date)), anchor: .center)
                    .transaction { $0.disablesAnimations = true }
                    .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
            }
            .background {
                Circle().fill(symbol.opacity(hovering && model.selectedTab != nil ? 0.16 : 0))
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(symbol)
        .opacity(model.selectedTab == nil ? 0.38 : 1)
        .disabled(model.selectedTab == nil)
        .help(loading ? "Stop" : "Reload")
        .accessibilityLabel(loading ? "Stop" : "Reload")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear { adopt(loading: loading, immediate: false) }
        .onChange(of: loading) { _, now in
            adopt(loading: now, immediate: false)
        }
        .onChange(of: tabID) { _, _ in
            adopt(loading: model.selectedTab?.isLoading == true, immediate: true)
        }
    }

    private func activate() {
        if loading {
            model.selectedTab?.stopLoading()
        } else {
            model.selectedTab?.reload()
        }
    }

    /// `immediate` skips the flash window, for a tab that is already loading.
    private func adopt(loading: Bool, immediate: Bool) {
        pending?.cancel()
        pending = nil
        if loading {
            if immediate {
                beginSpin()
            } else if !isSpinning {
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    guard model.selectedTab?.isLoading == true else { return }
                    beginSpin()
                }
            }
        } else if immediate {
            phase = .idle
        } else {
            beginSettle()
        }
    }

    private var isSpinning: Bool {
        if case .spinning = phase { return true }
        return false
    }

    private func beginSpin() {
        let now = Date()
        phase = .spinning(from: now, base: displayedAngle(at: now))
    }

    /// Coast to the upright arrow, then decelerate so the stop is not a snap.
    private func beginSettle() {
        guard case .spinning = phase else { return }
        let now = Date()
        let current = displayedAngle(at: now)
        let omega = 360 / revolution
        let positive = positiveMod(current, 360)
        if positive < 1.5 {
            phase = .idle
            return
        }
        let easeDistance = 72.0
        var coast = 360 - positive
        if coast < easeDistance { coast += 360 }
        let tail = easeDistance
        let linear = coast - tail
        let linearTime = linear / omega
        let easeTime = tail * 3 / omega
        phase = .settling(
            from: now,
            start: current,
            linearTime: linearTime,
            easeTime: easeTime,
            omega: omega,
            tail: tail
        )
        pending = Task {
            try? await Task.sleep(for: .seconds(linearTime + easeTime))
            guard !Task.isCancelled else { return }
            phase = .idle
        }
    }

    private func displayedAngle(at date: Date) -> Double {
        switch phase {
        case .idle:
            return 0
        case .spinning(let from, let base):
            return base + date.timeIntervalSince(from) / revolution * 360
        case .settling(let from, let start, let linearTime, let easeTime, let omega, let tail):
            let elapsed = date.timeIntervalSince(from)
            if elapsed <= linearTime {
                return start + omega * elapsed
            }
            let t = min(1, (elapsed - linearTime) / easeTime)
            let eased = 1 - pow(1 - t, 3)
            return start + omega * linearTime + tail * eased
        }
    }

    private func positiveMod(_ value: Double, _ modulus: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }

    private enum Phase {
        case idle
        case spinning(from: Date, base: Double)
        case settling(
            from: Date,
            start: Double,
            linearTime: TimeInterval,
            easeTime: TimeInterval,
            omega: Double,
            tail: Double
        )
    }
}
