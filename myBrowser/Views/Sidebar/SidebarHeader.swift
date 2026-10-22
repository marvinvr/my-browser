import SwiftUI

/// The sidebar's top row when the address bar sits above the page.
/// Traffic lights and the hide button share one line. Sidebar address-bar mode uses `ContentToolbar` instead.
struct SidebarHeader: View {
    var traffic: TrafficLightAnchor

    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(traffic.clearance, SidebarMetrics.minimumTrafficClearance))
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            SidebarHeaderButton(systemName: "sidebar.left", help: "Hide Sidebar") {
                model.toggleSidebar()
            }
        }
        .frame(height: SidebarMetrics.navRowHeight)
        .padding(.top, topPadding)
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }

    /// Same centre as the content toolbar, so the lights do not jump when the sidebar collapses.
    private var topPadding: CGFloat {
        max(0, SidebarMetrics.chromeCenterFromTop - SidebarMetrics.navRowHeight / 2)
    }
}

private struct SidebarHeaderButton: View {
    var systemName: String
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background {
                    Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
