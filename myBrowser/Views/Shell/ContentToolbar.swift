import AppKit
import SwiftUI

/// Back, forward, reload, and the address field.
///
/// `.content` is one row above the page. The bar crossfades to a quiet wash of the page
/// colour. The URL is plain text; a neutral field appears only on hover or while editing.
/// `.sidebar` puts the same controls on the traffic-light row, with a pill underneath.
/// Sidebar chrome stays untinted so the symbols sit on the vibrancy material.
/// When the sidebar is hidden, the content bar insets its controls past the traffic lights.
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
    /// Nil until the first tint is known, so the first frame uses `targetChrome` for this appearance.
    @State private var painted: ToolbarChrome?

    private let leadingPadding: CGFloat = 10

    private var targetChrome: ToolbarChrome {
        ToolbarChrome.resolve(tint: model.selectedTab?.themeColor, colorScheme: colorScheme)
    }

    /// Neutral chrome for the sidebar. The page tint is not painted behind these controls.
    private var sidebarChrome: ToolbarChrome {
        ToolbarChrome.resolve(tint: nil, colorScheme: colorScheme)
    }

    /// Quantized so a fresh `NSColor` each pass does not restart the crossfade.
    private var tintToken: TintToken {
        TintToken(scheme: colorScheme, color: model.selectedTab?.themeColor)
    }

    private var shown: ToolbarChrome { painted ?? targetChrome }

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
                .padding(.leading, leadingPadding)
                .padding(.trailing, leadingPadding + 6)
                .frame(height: SidebarMetrics.toolbarHeight - SidebarMetrics.progressHeight)
            progressTrack(shown)
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
            AddressField(chrome: shown, presentation: .inline)
                .frame(minWidth: 40, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                .padding(.leading, 6)
            DownloadsToolbarButton(symbol: shown.symbol)
            PictureInPictureButton(symbol: shown.symbol)
            ExtensionButtons()
                .layoutPriority(1)
                .padding(.leading, 4)
        }
        .animation(SidebarMotion.sidebar, value: sidebarVisible)
    }

    /// Sidebar placement: navigation shares the traffic-light row; the address field sits below it.
    private var sidebarBody: some View {
        let chrome = sidebarChrome
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: max(traffic.clearance, SidebarMetrics.minimumTrafficClearance))
                    .accessibilityHidden(true)
                NavigationButtons(chrome: chrome)
                Spacer(minLength: 4)
                DownloadsToolbarButton(symbol: chrome.symbol)
                ToolbarIconButton(systemName: "sidebar.left", help: "Hide Sidebar", symbol: chrome.symbol) {
                    model.toggleSidebar()
                }
            }
            .padding(.trailing, 8 - SidebarMetrics.leadingInset)
            .frame(height: SidebarMetrics.navRowHeight)
            .padding(.top, max(0, SidebarMetrics.chromeCenterFromTop - SidebarMetrics.navRowHeight / 2))

            HStack(spacing: 4) {
                AddressField(chrome: chrome, presentation: .pill)
                PictureInPictureButton(symbol: chrome.symbol)
            }
            .padding(.leading, 8 + SidebarMetrics.leadingInset)
            .padding(.trailing, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ExtensionButtons()
            }
            .padding(.trailing, 8 - SidebarMetrics.leadingInset)
            .padding(.bottom, 2)
            progressTrack(chrome)
        }
    }

    /// The collapsed card is flush with the window, so clearance is the whole leading inset.
    private var trafficSpacer: CGFloat {
        let clearance = max(traffic.clearance, SidebarMetrics.minimumTrafficClearance)
        return max(0, clearance - leadingPadding)
    }

    private func progressTrack(_ chrome: ToolbarChrome) -> some View {
        let loading = model.selectedTab?.isLoading == true
        let progress = model.selectedTab?.estimatedProgress ?? 0
        return ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(chrome.symbol.opacity(0.22))
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

/// Shown while the selected tab has a playing video that allows Picture in Picture.
private struct PictureInPictureButton: View {
    var symbol: Color

    @Environment(BrowserModel.self) private var model

    var body: some View {
        let tab = model.selectedTab
        let active = tab?.isPictureInPictureActive == true
        if tab?.showsPictureInPictureButton == true {
            ToolbarIconButton(
                systemName: active ? "pip.exit" : "pip.enter",
                help: active ? "Exit Picture in Picture" : "Enter Picture in Picture",
                symbol: symbol
            ) {
                model.togglePictureInPicture()
            }
            .transition(.opacity)
        }
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
