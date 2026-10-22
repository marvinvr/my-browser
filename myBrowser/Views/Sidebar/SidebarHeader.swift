import SwiftUI

/// The sidebar's top row: kept clear of the traffic lights, with a button to hide the sidebar.
/// Back, forward, reload, and the address field live in `ContentToolbar`.
struct SidebarHeader: View {
    var traffic: TrafficLightAnchor

    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, traffic.clearance))
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

    private var topPadding: CGFloat {
        max(0, traffic.centerFromTop - SidebarMetrics.navRowHeight / 2)
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
