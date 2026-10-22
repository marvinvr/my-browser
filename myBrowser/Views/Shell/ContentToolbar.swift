import SwiftUI

/// Compact toolbar above the page: back, forward, reload, and the address capsule.
/// When the sidebar is hidden, controls are inset so they clear the traffic lights.
struct ContentToolbar: View {
    var traffic: TrafficLightAnchor
    var sidebarVisible: Bool

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private let leadingPadding: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, leadingPadding)
                .frame(height: SidebarMetrics.toolbarHeight - SidebarMetrics.progressHeight)
            progressTrack
        }
        .frame(height: SidebarMetrics.toolbarHeight)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if !sidebarVisible {
                Color.clear
                    .frame(width: trafficSpacer)
                    .accessibilityHidden(true)
                ToolbarIconButton(systemName: "sidebar.left", help: "Show Sidebar") {
                    model.toggleSidebar()
                }
                .padding(.trailing, 4)
            }

            navigationCluster
            addressField
                .frame(maxWidth: .infinity)
                .padding(.leading, 8)
        }
        .animation(SidebarMotion.sidebar, value: sidebarVisible)
    }

    /// Distance from the card's padded leading edge to the first control, when the sidebar is hidden.
    /// The card already starts `contentInset` points from the window edge.
    private var trafficSpacer: CGFloat {
        max(0, traffic.clearance - SidebarMetrics.contentInset - leadingPadding)
    }

    private var navigationCluster: some View {
        HStack(spacing: 0) {
            ToolbarIconButton(
                systemName: "chevron.left",
                enabled: model.selectedTab?.canGoBack == true,
                help: "Back"
            ) {
                model.selectedTab?.goBack()
            }
            ToolbarIconButton(
                systemName: "chevron.right",
                enabled: model.selectedTab?.canGoForward == true,
                help: "Forward"
            ) {
                model.selectedTab?.goForward()
            }
            ToolbarIconButton(
                systemName: isLoading ? "stop.fill" : "arrow.clockwise",
                enabled: model.selectedTab != nil,
                help: isLoading ? "Stop" : "Reload"
            ) {
                if isLoading {
                    model.selectedTab?.stopLoading()
                } else {
                    model.selectedTab?.reload()
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: SidebarMetrics.toolbarControl)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var addressField: some View {
        let current = address
        return Button {
            model.showCommandBar(.editCurrent)
        } label: {
            Text(current.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(current.isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .frame(height: SidebarMetrics.toolbarControl)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05))
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12), lineWidth: 1)
        }
        .accessibilityLabel("Address")
        .accessibilityValue(current.text)
        .help("Edit Address")
    }

    private var isLoading: Bool {
        model.selectedTab?.isLoading == true
    }

    private var address: (text: String, isPlaceholder: Bool) {
        let url = model.selectedTab?.url
            ?? model.selectedItemID.flatMap { model.library.item($0)?.url }
        if let host = SidebarTitle.host(of: url) {
            return (host, false)
        }
        return ("Search or enter URL", true)
    }

    private var progressTrack: some View {
        let loading = model.selectedTab?.isLoading == true
        let progress = model.selectedTab?.estimatedProgress ?? 0
        return ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .animation(.spring(duration: 0.25, bounce: 0), value: progress)
            }
            .opacity(loading ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: loading)
        }
        .frame(height: SidebarMetrics.progressHeight)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Plain icon button sized to sit inside the toolbar's glass capsule.
private struct ToolbarIconButton: View {
    var systemName: String
    var enabled: Bool = true
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
                .background {
                    Circle().fill(Color.primary.opacity(hovering && enabled ? 0.08 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .opacity(enabled ? 1 : 0.32)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: systemName)
    }
}
