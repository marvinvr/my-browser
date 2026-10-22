import AppKit
import SwiftUI

/// Compact toolbar above the page. The controls live in `Views/Toolbar` so the sidebar can reuse them.
/// When the sidebar is hidden, controls are inset so they clear the traffic lights.
struct ContentToolbar: View {
    var traffic: TrafficLightAnchor
    var sidebarVisible: Bool

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    /// Nil until the first tint is known, so the first frame uses `targetChrome` for this appearance.
    @State private var painted: ToolbarChrome?

    private let leadingPadding: CGFloat = 10

    private var targetChrome: ToolbarChrome {
        ToolbarChrome.resolve(tint: model.selectedTab?.themeColor, colorScheme: colorScheme)
    }

    /// Quantized so a fresh `NSColor` each pass does not restart the crossfade.
    private var tintToken: TintToken {
        TintToken(scheme: colorScheme, color: model.selectedTab?.themeColor)
    }

    private var shown: ToolbarChrome { painted ?? targetChrome }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, leadingPadding)
                .frame(height: SidebarMetrics.toolbarHeight - SidebarMetrics.progressHeight)
            progressTrack
        }
        .frame(height: SidebarMetrics.toolbarHeight)
        .background {
            shown.background.opacity(shown.isTinted ? 1 : 0)
        }
        .onAppear { painted = targetChrome }
        .onChange(of: tintToken) { _, _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                painted = targetChrome
            }
        }
        .onChange(of: colorScheme) { _, _ in
            model.selectedTab?.refreshThemeColor()
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            if !sidebarVisible {
                Color.clear
                    .frame(width: trafficSpacer)
                    .accessibilityHidden(true)
                ToolbarIconButton(systemName: "sidebar.left", help: "Show Sidebar", symbol: shown.symbol) {
                    model.toggleSidebar()
                }
                .padding(.trailing, 4)
            }

            NavigationButtons(chrome: shown)
            AddressField(chrome: shown)
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

    private var progressTrack: some View {
        let loading = model.selectedTab?.isLoading == true
        let progress = model.selectedTab?.estimatedProgress ?? 0
        return ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(shown.symbol.opacity(0.22))
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

/// Identity of the page tint. Components are rounded so equivalent colours compare equal.
private struct TintToken: Equatable {
    var scheme: ColorScheme
    var r: Int?
    var g: Int?
    var b: Int?
    var a: Int?

    init(scheme: ColorScheme, color: NSColor?) {
        self.scheme = scheme
        guard let srgb = color?.usingColorSpace(.sRGB) else { return }
        r = Self.quantize(srgb.redComponent)
        g = Self.quantize(srgb.greenComponent)
        b = Self.quantize(srgb.blueComponent)
        a = Self.quantize(srgb.alphaComponent)
    }

    private static func quantize(_ value: CGFloat) -> Int {
        Int((Double(value) * 1000).rounded())
    }
}
