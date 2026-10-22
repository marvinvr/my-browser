import SwiftUI

/// Back, forward, and reload/stop. Reads `BrowserModel` from the environment.
///
/// The reload glyph stays on a fixed frame and only crossfades to stop once loading has
/// lasted 150ms, so a fast load or a one-frame `isLoading` blip does not move the bar.
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

/// Reload and stop occupy the same frame. Opacity swaps them; the bar does not relayout.
private struct ReloadButton: View {
    var symbol: Color

    @Environment(BrowserModel.self) private var model
    @State private var showsStop = false
    @State private var pending: Task<Void, Never>?

    private var loading: Bool { model.selectedTab?.isLoading == true }
    private var tabID: UUID? { model.selectedTab?.id }

    var body: some View {
        Button(action: activate) {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .opacity(showsStop ? 0 : 1)
                Image(systemName: "stop.fill")
                    .opacity(showsStop ? 1 : 0)
            }
            .font(.system(size: 12, weight: .semibold))
            .symbolRenderingMode(.monochrome)
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
        .help(showsStop ? "Stop" : "Reload")
        .accessibilityLabel(showsStop ? "Stop" : "Reload")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.15), value: showsStop)
        .onAppear { adopt(loading: loading, immediate: false) }
        .onChange(of: loading) { _, now in
            adopt(loading: now, immediate: false)
        }
        .onChange(of: tabID) { _, _ in
            adopt(loading: model.selectedTab?.isLoading == true, immediate: true)
        }
    }

    @State private var hovering = false

    private func activate() {
        if showsStop {
            model.selectedTab?.stopLoading()
        } else {
            model.selectedTab?.reload()
        }
    }

    /// `immediate` is for a tab that is already loading: show stop without waiting out a flash window.
    private func adopt(loading: Bool, immediate: Bool) {
        pending?.cancel()
        pending = nil
        if immediate {
            showsStop = loading
            return
        }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            guard (model.selectedTab?.isLoading == true) == loading else { return }
            showsStop = loading
        }
    }
}
