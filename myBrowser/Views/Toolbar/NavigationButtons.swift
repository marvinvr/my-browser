import SwiftUI

/// Back, forward, and reload/stop. Reads `BrowserModel` from the environment.
///
/// While a page loads, the reload arrow itself spins. A load shorter than 150ms does not
/// start the spin. When loading ends the symbol effect settles upright. Clicking during a load stops it.
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

/// The reload arrow spins on the symbol's own ring anchor for the duration of a load.
/// About one turn every 0.65s. Clearing `spinning` settles upright at that rate.
private struct ReloadButton: View {
    var symbol: Color

    @Environment(BrowserModel.self) private var model
    @State private var hovering = false
    @State private var spinning = false
    @State private var pending: Task<Void, Never>?

    private var loading: Bool { model.selectedTab?.isLoading == true }
    private var tabID: UUID? { model.selectedTab?.id }

    var body: some View {
        Button(action: activate) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .symbolEffect(
                    .rotate.byLayer.clockwise,
                    options: .repeat(.continuous).speed(2.8),
                    isActive: spinning
                )
                .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
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
                    guard model.selectedTab?.isLoading == true else { return }
                    spinning = true
                }
            }
        } else {
            spinning = false
        }
    }
}
