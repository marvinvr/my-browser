import AppKit
import SwiftUI

/// Window chrome: vibrancy, resizable sidebar, and the inset content card.
/// `WebContentView` fills the card; this view clips and shadows it.
struct MainWindowView: View {
    @Environment(BrowserModel.self) private var model
    @AppStorage(SidebarMetrics.widthDefaultsKey) private var storedSidebarWidth = SidebarMetrics.defaultWidth
    @AppStorage(AddressBarPosition.defaultsKey) private var addressBarPosition: AddressBarPosition = .top
    @State private var draggedWidth: Double?
    @State private var dragOrigin: Double?
    @State private var traffic = TrafficLightAnchor.fallback

    var body: some View {
        let sidebarVisible = model.session.isSidebarVisible
        let fullWidth = CGFloat(resolvedWidth)
        let shownWidth = sidebarVisible ? fullWidth : 0

        ZStack {
            SidebarBackdrop(tint: model.selectedSpace?.color.color)
                .animation(SidebarMotion.space, value: model.selectedSpaceID)

            HStack(spacing: 0) {
                sidebarColumn(shownWidth: shownWidth, fullWidth: fullWidth, visible: sidebarVisible)
                gap(visible: sidebarVisible)
                contentCard(sidebarVisible: sidebarVisible)
            }
            .animation(SidebarMotion.sidebar, value: sidebarVisible)
            .animation(SidebarMotion.sidebar, value: addressBarPosition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background {
            WindowConfigurator(anchor: $traffic)
        }
        .overlay { CommandBarOverlay() }
        .focusedSceneValue(\.browserNavigation, BrowserNavigationState(
            canGoBack: model.canGoBack,
            canGoForward: model.canGoForward,
            canReload: model.canReload
        ))
        .focusedSceneValue(\.sidebarIsVisible, sidebarVisible)
        .onAppear {
            let clamped = min(SidebarMetrics.maxWidth, max(SidebarMetrics.minWidth, storedSidebarWidth))
            if clamped != storedSidebarWidth {
                storedSidebarWidth = clamped
            }
        }
    }

    private var resolvedWidth: Double {
        let raw = draggedWidth ?? storedSidebarWidth
        return min(SidebarMetrics.maxWidth, max(SidebarMetrics.minWidth, raw))
    }

    /// The clip width animates; the sidebar itself stays at its real width so rows don't squash.
    private func sidebarColumn(shownWidth: CGFloat, fullWidth: CGFloat, visible: Bool) -> some View {
        Color.clear
            .frame(width: shownWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                SidebarView(traffic: traffic)
                    .frame(width: fullWidth)
                    .frame(maxHeight: .infinity)
            }
            .clipped()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    /// Leading inset of the content card. While the sidebar is open this is also the drag handle.
    /// Collapsed, the gap is zero so the card meets the window edge.
    private func gap(visible: Bool) -> some View {
        Color.clear
            .frame(width: visible ? SidebarMetrics.contentInset : 0)
            .frame(maxHeight: .infinity)
            .overlay {
                if visible {
                    SidebarResizeHandle(width: resolvedWidth, onDrag: resize)
                }
            }
    }

    /// Sidebar address-bar position hides the content toolbar while the sidebar is open.
    /// Collapsed, the toolbar comes back so the URL stays on screen.
    private func showsContentToolbar(sidebarVisible: Bool) -> Bool {
        switch addressBarPosition {
        case .top: true
        case .sidebar: !sidebarVisible
        }
    }

    private func contentCard(sidebarVisible: Bool) -> some View {
        let inset = sidebarVisible ? SidebarMetrics.contentInset : 0
        let showsToolbar = showsContentToolbar(sidebarVisible: sidebarVisible)
        // Outer inset and this spacer trade off, so the toolbar stays on the traffic-light line.
        let topCompensation = showsToolbar && !sidebarVisible ? SidebarMetrics.contentInset : 0
        return VStack(spacing: 0) {
            Color.clear
                .frame(height: topCompensation)
                .accessibilityHidden(true)
            if showsToolbar {
                ContentToolbar(traffic: traffic, sidebarVisible: sidebarVisible)
                    .transition(.opacity)
            }
            WebContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(
            cornerRadius: sidebarVisible ? SidebarMetrics.cardCornerRadius : 0,
            style: .continuous
        ))
        .shadow(
            color: Color.black.opacity(sidebarVisible ? 0.16 : 0),
            radius: sidebarVisible ? 5 : 0,
            y: sidebarVisible ? 1 : 0
        )
        .padding(.top, inset)
        .padding(.bottom, inset)
        .padding(.trailing, inset)
    }

    private func resize(translation: CGFloat, ended: Bool) {
        if dragOrigin == nil {
            dragOrigin = storedSidebarWidth
        }
        let origin = dragOrigin ?? storedSidebarWidth
        let next = min(SidebarMetrics.maxWidth, max(SidebarMetrics.minWidth, origin + Double(translation)))
        if ended {
            storedSidebarWidth = next
            draggedWidth = nil
            dragOrigin = nil
        } else {
            draggedWidth = next
        }
    }
}

#if DEBUG
#Preview("Window") {
    PreviewHost {
        MainWindowView()
    }
    .frame(width: 1100, height: 720)
}

#Preview("Window, sidebar hidden") {
    PreviewHost(sidebarVisible: false) {
        MainWindowView()
    }
    .frame(width: 1100, height: 720)
}
#endif
