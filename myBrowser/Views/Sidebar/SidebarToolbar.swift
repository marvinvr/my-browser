import SwiftUI

/// Back, forward, and reload/stop, aligned with the traffic lights, plus the address pill.
struct SidebarToolbar: View {
    var traffic: TrafficLightAnchor

    @Environment(BrowserModel.self) private var model

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 2) {
                Color.clear
                    .frame(width: max(0, traffic.clearance))
                    .accessibilityHidden(true)
                SidebarIconButton(
                    systemName: "chevron.left",
                    enabled: model.selectedTab?.canGoBack == true,
                    help: "Back"
                ) {
                    model.selectedTab?.goBack()
                }
                SidebarIconButton(
                    systemName: "chevron.right",
                    enabled: model.selectedTab?.canGoForward == true,
                    help: "Forward"
                ) {
                    model.selectedTab?.goForward()
                }
                SidebarIconButton(
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
                Spacer(minLength: 0)
            }
            .frame(height: SidebarMetrics.navRowHeight)
            .padding(.top, topPadding)
            .padding(.trailing, 8)

            GlassEffectContainer(spacing: 8) {
                addressPill
            }
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 6)
    }

    private var isLoading: Bool {
        model.selectedTab?.isLoading == true
    }

    private var topPadding: CGFloat {
        max(0, traffic.centerFromTop - SidebarMetrics.navRowHeight / 2)
    }

    private var address: (text: String, isPlaceholder: Bool) {
        let url = model.selectedTab?.url
            ?? model.selectedItemID.flatMap { model.library.item($0)?.url }
        if let host = SidebarTitle.host(of: url) {
            return (host, false)
        }
        return ("Search or enter URL", true)
    }

    private var addressPill: some View {
        let current = address
        return Button {
            model.showCommandBar(.editCurrent)
        } label: {
            Text(current.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(current.isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Address")
        .accessibilityValue(current.text)
    }
}

private struct SidebarIconButton: View {
    var systemName: String
    var enabled: Bool
    var help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
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
        .animation(SidebarMotion.selection, value: hovering)
        .animation(SidebarMotion.selection, value: systemName)
    }
}
