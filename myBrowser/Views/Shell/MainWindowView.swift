import AppKit
import SwiftUI

/// Window chrome: vibrancy, resizable sidebar, and the inset content card.
/// `WebContentView` fills the card; this view clips and shadows it.
struct MainWindowView: View {
    @Environment(BrowserModel.self) private var model
    @AppStorage(SidebarMetrics.widthDefaultsKey) private var storedSidebarWidth = SidebarMetrics.defaultWidth
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
                contentCard
            }
            .animation(SidebarMotion.sidebar, value: sidebarVisible)
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
    private func gap(visible: Bool) -> some View {
        Color.clear
            .frame(width: SidebarMetrics.contentInset)
            .frame(maxHeight: .infinity)
            .overlay {
                if visible {
                    SidebarResizeHandle(width: resolvedWidth, onDrag: resize)
                }
            }
    }

    private var contentCard: some View {
        WebContentView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: SidebarMetrics.cardCornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.16), radius: 5, y: 1)
            .padding(.top, SidebarMetrics.contentInset)
            .padding(.bottom, SidebarMetrics.contentInset)
            .padding(.trailing, SidebarMetrics.contentInset)
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
