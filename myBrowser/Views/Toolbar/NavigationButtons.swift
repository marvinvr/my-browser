import SwiftUI

/// Back, forward, and reload/stop. Reads `BrowserModel` from the environment.
///
/// While a page loads, the reload arrow itself spins. A load shorter than 150ms does not
/// start the spin. When loading ends the symbol effect settles upright. Clicking during a load stops it.
struct NavigationButtons: View {
    var chrome: ToolbarChrome? = nil
    /// Set on a split pane. Nil follows the selected tab, which is the shared toolbar.
    var tabID: UUID? = nil
    var metrics: ToolbarButtonMetrics = .regular
    /// A narrow pane toolbar drops Forward into its menu.
    var showsForward: Bool = true

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var tab: BrowserTab? {
        if let tabID { return model.tabs[tabID] }
        return model.selectedTab
    }

    private var resolved: ToolbarChrome {
        chrome ?? ToolbarChrome.resolve(tint: tab?.themeColor, colorScheme: colorScheme)
    }

    var body: some View {
        let count = showsForward ? 3 : 2
        HStack(spacing: 0) {
            ToolbarIconButton(
                systemName: "chevron.left",
                enabled: tab?.canGoBack == true,
                help: "Back",
                symbol: resolved.symbol,
                diameter: metrics.diameter,
                glyph: metrics.glyph
            ) {
                focusIfNeeded()
                tab?.goBack()
            }
            if showsForward {
                ToolbarIconButton(
                    systemName: "chevron.right",
                    enabled: tab?.canGoForward == true,
                    help: "Forward",
                    symbol: resolved.symbol,
                    diameter: metrics.diameter,
                    glyph: metrics.glyph
                ) {
                    focusIfNeeded()
                    tab?.goForward()
                }
            }
            ReloadButton(
                symbol: resolved.symbol,
                tabID: tabID,
                diameter: metrics.diameter,
                glyph: metrics.glyph
            )
        }
        .padding(.horizontal, metrics.clusterPadding)
        .frame(
            width: metrics.diameter * CGFloat(count) + metrics.clusterPadding * 2,
            height: metrics.diameter
        )
    }

    private func focusIfNeeded() {
        if let tabID { model.focusPane(tabID: tabID) }
    }
}

/// Hit size for one toolbar icon. `.regular` is the shared bar. Pane bars pass a smaller size.
struct ToolbarButtonMetrics: Equatable {
    var diameter: CGFloat
    var glyph: CGFloat
    var clusterPadding: CGFloat

    static let regular = ToolbarButtonMetrics(
        diameter: SidebarMetrics.toolbarControl,
        glyph: 12,
        clusterPadding: 2
    )
}

/// Icon button with a constant frame. The symbol colour is explicit so it stays legible on a tint.
struct ToolbarIconButton: View {
    var systemName: String
    var enabled: Bool = true
    var help: String
    var symbol: Color
    var diameter: CGFloat = SidebarMetrics.toolbarControl
    var glyph: CGFloat = 12
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyph, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: diameter, height: diameter)
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

/// The reload arrow spins on the symbol's own ring anchor for the duration of a load.
/// About one turn every 0.65s. Clearing `spinning` settles upright at that rate.
private struct ReloadButton: View {
    var symbol: Color
    var tabID: UUID? = nil
    var diameter: CGFloat = SidebarMetrics.toolbarControl
    var glyph: CGFloat = 12

    @Environment(BrowserModel.self) private var model
    @State private var hovering = false
    @State private var spinning = false
    @State private var pending: Task<Void, Never>?

    private var tab: BrowserTab? {
        if let tabID { return model.tabs[tabID] }
        return model.selectedTab
    }

    private var loading: Bool { tab?.isLoading == true }
    private var identity: UUID? { tab?.id }

    var body: some View {
        Button(action: activate) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: glyph, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolEffect(
                    .rotate.byLayer.clockwise,
                    options: .repeat(.continuous).speed(2.8),
                    isActive: spinning
                )
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(symbol.opacity(hovering && tab != nil ? 0.16 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(symbol)
        .opacity(tab == nil ? 0.38 : 1)
        .disabled(tab == nil)
        .help(loading ? "Stop" : "Reload")
        .accessibilityLabel(loading ? "Stop" : "Reload")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear { adopt(loading: loading, immediate: false) }
        .onChange(of: loading) { _, now in
            adopt(loading: now, immediate: false)
        }
        .onChange(of: identity) { _, _ in
            adopt(loading: tab?.isLoading == true, immediate: true)
        }
    }

    private func activate() {
        if let tabID { model.focusPane(tabID: tabID) }
        if loading {
            tab?.stopLoading()
        } else {
            tab?.reload()
        }
    }

    /// `immediate` skips the flash window, for a tab that is already loading.
    /// Ending the load drops `spinning`; the rotate effect settles on its own.
    private func adopt(loading: Bool, immediate: Bool) {
        pending?.cancel()
        pending = nil
        if loading {
            if immediate || spinning {
                spinning = true
            } else {
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    guard tab?.isLoading == true else { return }
                    spinning = true
                }
            }
        } else {
            spinning = false
        }
    }
}
