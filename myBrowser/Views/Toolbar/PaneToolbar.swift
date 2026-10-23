import AppKit
import SwiftUI

/// Drives one split pane's toolbar without rebuilding the hosting view on focus changes.
@Observable
final class PaneToolbarDriver {
    var tabID: UUID = UUID()
    var focused = false
    /// The pane under the traffic lights. Only that bar reserves their clearance.
    var isLeading = false
    /// Sidebar toggle, downloads, extensions, and Picture in Picture.
    /// One pane holds them: the top bar when stacked, the trailing bar when side by side.
    var showsWindowControls = false
    var trafficClearance: CGFloat = SidebarMetrics.minimumTrafficClearance
}

/// The content toolbar, repeated above one split pane.
///
/// The focused bar uses the page tint. The others drop to a quieter opacity and stay
/// clickable: back, forward, reload, and the URL focus this pane, then run.
/// Window controls stay full strength on whichever pane holds them.
struct PaneToolbar: View {
    var driver: PaneToolbarDriver

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var painted: ToolbarChrome?

    private let leadingPadding: CGFloat = 10

    private var tab: BrowserTab? { model.tabs[driver.tabID] }

    private var sidebarVisible: Bool { model.session.isSidebarVisible }

    private var targetChrome: ToolbarChrome {
        let tint = driver.focused ? tab?.themeColor : nil
        return ToolbarChrome.resolve(tint: tint, colorScheme: colorScheme)
    }

    private var tintToken: PaneTintToken {
        PaneTintToken(scheme: colorScheme, focused: driver.focused, color: driver.focused ? tab?.themeColor : nil)
    }

    private var shown: ToolbarChrome { painted ?? targetChrome }

    /// Room so the leading pane's buttons clear the traffic lights when the sidebar is hidden.
    private var trafficSpacer: CGFloat {
        guard driver.isLeading, !sidebarVisible else { return 0 }
        let clearance = max(driver.trafficClearance, SidebarMetrics.minimumTrafficClearance)
        return max(0, clearance - leadingPadding)
    }

    var body: some View {
        let chrome = shown
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                paneControls(chrome)
                if driver.showsWindowControls {
                    windowControls(chrome)
                }
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, leadingPadding + 6)
            .frame(height: SidebarMetrics.toolbarHeight - SidebarMetrics.progressHeight)
            ToolbarProgressTrack(
                loading: tab?.isLoading == true,
                progress: tab?.estimatedProgress ?? 0,
                symbol: chrome.symbol
            )
        }
        .frame(height: SidebarMetrics.toolbarHeight)
        .background {
            chrome.background.opacity(driver.focused && chrome.isTinted ? 1 : 0)
        }
        .onAppear { painted = targetChrome }
        .onChange(of: tintToken) { _, _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                painted = targetChrome
            }
        }
        .onChange(of: colorScheme) { _, _ in
            tab?.refreshThemeColor()
        }
    }

    private func paneControls(_ chrome: ToolbarChrome) -> some View {
        HStack(spacing: 0) {
            if trafficSpacer > 0 {
                Color.clear
                    .frame(width: trafficSpacer)
                    .accessibilityHidden(true)
            }
            NavigationButtons(chrome: chrome, tabID: driver.tabID)
            AddressField(chrome: chrome, presentation: .inline, tabID: driver.tabID)
                .frame(minWidth: 28, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
                .padding(.leading, 6)
        }
        .opacity(driver.focused ? 1 : 0.48)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.focusPane(tabID: driver.tabID) })
    }

    private func windowControls(_ chrome: ToolbarChrome) -> some View {
        HStack(spacing: 0) {
            if !sidebarVisible {
                ToolbarIconButton(systemName: "sidebar.left", help: "Show Sidebar", symbol: chrome.symbol) {
                    model.toggleSidebar()
                }
                .padding(.trailing, 4)
            }
            DownloadsToolbarButton(symbol: chrome.symbol)
            PictureInPictureButton(symbol: chrome.symbol)
            ExtensionButtons()
                .layoutPriority(1)
                .padding(.leading, 4)
        }
    }
}

/// Identity of one pane's tint, including whether this bar is the focused one.
private struct PaneTintToken: Equatable {
    var scheme: ColorScheme
    var focused: Bool
    var r: Int?
    var g: Int?
    var b: Int?
    var a: Int?

    init(scheme: ColorScheme, focused: Bool, color: NSColor?) {
        self.scheme = scheme
        self.focused = focused
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

/// Hosted once per pane. The driver is mutated in place so hover and tint state survive focus changes.
struct HostedPaneToolbar: View {
    var driver: PaneToolbarDriver
    var browser: BrowserModel
    var extensions: ExtensionManager

    var body: some View {
        PaneToolbar(driver: driver)
            .environment(browser)
            .environment(extensions)
    }
}
