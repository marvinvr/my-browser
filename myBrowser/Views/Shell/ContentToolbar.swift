import SwiftUI

/// Back, forward, reload, and the address field.
///
/// `.content` is one row above the page. `.sidebar` puts navigation on the traffic-light
/// row and the address field underneath, the way Arc does. The field always shows the
/// live page host; glass is drawn behind the label so the text stays visible.
struct ContentToolbar: View {
    enum Style: Equatable {
        case content
        case sidebar
    }

    var traffic: TrafficLightAnchor
    var sidebarVisible: Bool
    var style: Style = .content

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private let leadingPadding: CGFloat = 10

    var body: some View {
        switch style {
        case .content:
            contentBody
        case .sidebar:
            sidebarBody
        }
    }

    private var contentBody: some View {
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

    /// Sidebar placement: navigation shares the traffic-light row; the address field sits below it.
    private var sidebarBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: max(traffic.clearance, SidebarMetrics.minimumTrafficClearance))
                    .accessibilityHidden(true)
                navigationCluster
                Spacer(minLength: 4)
                ToolbarIconButton(systemName: "sidebar.left", help: "Hide Sidebar") {
                    model.toggleSidebar()
                }
            }
            .padding(.trailing, 8)
            .frame(height: SidebarMetrics.navRowHeight)
            .padding(.top, max(0, SidebarMetrics.chromeCenterFromTop - SidebarMetrics.navRowHeight / 2))

            addressField
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 6)
            progressTrack
        }
    }

    /// The collapsed card is flush with the window, so clearance is the whole leading inset.
    private var trafficSpacer: CGFloat {
        let clearance = max(traffic.clearance, SidebarMetrics.minimumTrafficClearance)
        return max(0, clearance - leadingPadding)
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
        let current = addressText
        return Button {
            model.showCommandBar(.editCurrent)
        } label: {
            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05))
                    .glassEffect(.regular.interactive(), in: .capsule)
                Text(current.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(current.isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: SidebarMetrics.toolbarControl)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

    /// Live tab URL, then the sidebar item's URL. Reads both so the field updates when either changes.
    private var addressText: (text: String, isPlaceholder: Bool) {
        let tab = model.selectedTab
        let live = tab?.url ?? tab?.webView?.url
        let stored = model.selectedItemID.flatMap { model.library.item($0)?.url }
        let url = live ?? stored
        if let host = SidebarTitle.host(of: url) {
            return (host, false)
        }
        if let absolute = url?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines),
           !absolute.isEmpty, absolute != "about:blank" {
            return (absolute, false)
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
