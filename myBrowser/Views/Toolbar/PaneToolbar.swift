import AppKit
import SwiftUI

/// Sizes for the per-pane bar. Smaller than the shared toolbar so close, separate, and swap fit beside the URL.
enum PaneToolbarMetrics {
    static let control: CGFloat = 22
    static let glyph: CGFloat = 11
    static let pad: CGFloat = 6
    static let addressGap: CGFloat = 4
    static let actionsGap: CGFloat = 4
    static let windowGap: CGFloat = 4
    /// Field width, including the copy button, once the pane has room to spare.
    static let addressComfort: CGFloat = 128
    /// Field width with the copy button dropped, still enough for a short host.
    static let addressHost: CGFloat = 88
    /// Smallest field before a toolbar button moves into the menu.
    static let addressFloor: CGFloat = 56

    static var buttons: ToolbarButtonMetrics {
        ToolbarButtonMetrics(diameter: control, glyph: glyph, clusterPadding: 0)
    }
}

/// Which pane-toolbar controls stay on the bar. The URL shrinks first. Then the less important buttons move into the menu.
struct PaneToolbarFit: Equatable {
    var forward = true
    var separate = true
    var swap = true
    var windowControls = true
    var copyLink = true
    /// Width the address field keeps. Extra space still grows it.
    var addressMin: CGFloat = PaneToolbarMetrics.addressComfort

    /// The menu replaces toolbar buttons. Hiding the copy control does not, by itself, open one.
    var overflow: Bool {
        !forward || !separate || !swap || !windowControls
    }

    static func resolve(width: CGFloat, traffic: CGFloat, windowControlsWidth: CGFloat) -> PaneToolbarFit {
        var fit = PaneToolbarFit()
        guard width.isFinite, width > 1 else { return fit }
        if fits(fit, width: width, traffic: traffic, window: windowControlsWidth, address: PaneToolbarMetrics.addressComfort) {
            return fit
        }
        // The link button yields before separate, swap, or close, so the host stays readable.
        fit.copyLink = false
        fit.addressMin = PaneToolbarMetrics.addressHost
        if fits(fit, width: width, traffic: traffic, window: windowControlsWidth, address: PaneToolbarMetrics.addressHost) {
            return fit
        }
        fit.addressMin = PaneToolbarMetrics.addressFloor
        if fits(fit, width: width, traffic: traffic, window: windowControlsWidth, address: PaneToolbarMetrics.addressFloor) {
            return fit
        }
        let steps: [(inout PaneToolbarFit) -> Void] = [
            { $0.swap = false },
            { $0.separate = false },
            { if windowControlsWidth > 0 { $0.windowControls = false } },
            { $0.forward = false },
        ]
        for step in steps {
            step(&fit)
            if fits(fit, width: width, traffic: traffic, window: windowControlsWidth, address: PaneToolbarMetrics.addressFloor) {
                return fit
            }
        }
        return fit
    }

    static func used(_ fit: PaneToolbarFit, traffic: CGFloat, window: CGFloat, address: CGFloat) -> CGFloat {
        var total = PaneToolbarMetrics.pad * 2
            + traffic
            + PaneToolbarMetrics.addressGap
            + address
            + PaneToolbarMetrics.actionsGap
        total += PaneToolbarMetrics.control * 2
        if fit.forward { total += PaneToolbarMetrics.control }
        if fit.separate { total += PaneToolbarMetrics.control }
        if fit.swap { total += PaneToolbarMetrics.control }
        total += PaneToolbarMetrics.control
        if fit.overflow { total += PaneToolbarMetrics.control }
        if fit.windowControls, window > 0 {
            total += window + PaneToolbarMetrics.windowGap
        }
        return total
    }

    private static func fits(
        _ fit: PaneToolbarFit,
        width: CGFloat,
        traffic: CGFloat,
        window: CGFloat,
        address: CGFloat
    ) -> Bool {
        width + 0.5 >= used(fit, traffic: traffic, window: window, address: address)
    }
}

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
/// clickable. Back, forward, reload, the URL, and the pane actions focus this pane, then run.
/// Separate, swap, and close sit at the trailing end. Window controls stay full strength
/// on whichever pane holds them, just ahead of those actions.
struct PaneToolbar: View {
    var driver: PaneToolbarDriver

    @Environment(BrowserModel.self) private var model
    @Environment(ExtensionManager.self) private var extensions
    @Environment(\.colorScheme) private var colorScheme
    @State private var painted: ToolbarChrome?

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
        return max(0, clearance - PaneToolbarMetrics.pad)
    }

    /// Sidebar, downloads, Picture in Picture, and extension icons on this pane. Zero on the others.
    private var windowControlsWidth: CGFloat {
        guard driver.showsWindowControls else { return 0 }
        var width: CGFloat = 0
        if !sidebarVisible {
            width += SidebarMetrics.toolbarControl + 4
        }
        if model.downloads.toolbarVisible {
            width += SidebarMetrics.toolbarControl
        }
        if model.selectedTab?.showsPictureInPictureButton == true {
            width += SidebarMetrics.toolbarControl
        }
        if extensionButtonCount > 0 {
            width += 4 + CGFloat(extensionButtonCount) * SidebarMetrics.toolbarControl
        }
        return width
    }

    private var extensionButtonCount: Int {
        guard let profileID = model.selectedSpace?.profileID else { return 0 }
        let count = extensions.toolbarItems(profileID: profileID, tab: model.selectedTab).count
        guard count > 0 else { return 0 }
        return min(count, 4) + (count > 4 ? 1 : 0)
    }

    var body: some View {
        let chrome = shown
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let fit = PaneToolbarFit.resolve(
                    width: proxy.size.width,
                    traffic: trafficSpacer,
                    windowControlsWidth: windowControlsWidth
                )
                controls(chrome, fit: fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
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

    private func controls(_ chrome: ToolbarChrome, fit: PaneToolbarFit) -> some View {
        HStack(spacing: 0) {
            if trafficSpacer > 0 {
                Color.clear
                    .frame(width: trafficSpacer)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 0) {
                NavigationButtons(
                    chrome: chrome,
                    tabID: driver.tabID,
                    metrics: PaneToolbarMetrics.buttons,
                    showsForward: fit.forward
                )
                AddressField(
                    chrome: chrome,
                    presentation: .inline,
                    tabID: driver.tabID,
                    compact: true,
                    showsCopyButton: fit.copyLink
                )
                .padding(.leading, PaneToolbarMetrics.addressGap)
                .frame(minWidth: fit.addressMin, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            .opacity(driver.focused ? 1 : 0.48)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { model.focusPane(tabID: driver.tabID) })

            if driver.showsWindowControls, fit.windowControls {
                windowControls(chrome)
                    .padding(.leading, windowControlsWidth > 0 ? PaneToolbarMetrics.windowGap : 0)
            }

            paneActions(chrome, fit: fit)
                .padding(.leading, PaneToolbarMetrics.actionsGap)
                .opacity(driver.focused ? 1 : 0.48)
        }
        .padding(.horizontal, PaneToolbarMetrics.pad)
    }

    private func paneActions(_ chrome: ToolbarChrome, fit: PaneToolbarFit) -> some View {
        HStack(spacing: 0) {
            if fit.overflow {
                overflowMenu(chrome, fit: fit)
            }
            if fit.separate {
                paneButton("arrow.up.right.square", help: "Separate", symbol: chrome.symbol) {
                    separatePane()
                }
            }
            if fit.swap {
                paneButton("arrow.left.arrow.right", help: "Swap", symbol: chrome.symbol) {
                    swapThisPane()
                }
            }
            paneButton("xmark", help: "Close Pane", symbol: chrome.symbol) {
                closePane()
            }
        }
    }

    private func paneButton(
        _ systemName: String,
        help: String,
        symbol: Color,
        action: @escaping () -> Void
    ) -> some View {
        ToolbarIconButton(
            systemName: systemName,
            help: help,
            symbol: symbol,
            diameter: PaneToolbarMetrics.control,
            glyph: PaneToolbarMetrics.glyph,
            action: action
        )
        .accessibilityLabel(help == "Swap" ? "Swap Panes" : help)
    }

    private func overflowMenu(_ chrome: ToolbarChrome, fit: PaneToolbarFit) -> some View {
        Menu {
            if !fit.forward {
                Button("Forward") { goForward() }
                    .disabled(tab?.canGoForward != true)
            }
            if !fit.separate {
                Button("Separate") { separatePane() }
            }
            if !fit.swap {
                Button("Swap Panes") { swapThisPane() }
            }
            if !fit.copyLink {
                Button("Copy Link") { copyLink() }
            }
            if driver.showsWindowControls, !fit.windowControls {
                if !sidebarVisible {
                    Button("Show Sidebar") { model.toggleSidebar() }
                }
                if model.downloads.toolbarVisible {
                    Button("Downloads") { model.toggleDownloadsPage() }
                }
                if model.selectedTab?.showsPictureInPictureButton == true {
                    let active = model.selectedTab?.isPictureInPictureActive == true
                    Button(active ? "Exit Picture in Picture" : "Enter Picture in Picture") {
                        model.togglePictureInPicture()
                    }
                }
                if let profileID = model.selectedSpace?.profileID {
                    ForEach(extensions.toolbarItems(profileID: profileID, tab: model.selectedTab)) { item in
                        Button(item.label) {
                            extensions.performAction(extensionID: item.id, profileID: profileID, tab: model.selectedTab)
                        }
                        .disabled(!item.isEnabled)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: PaneToolbarMetrics.glyph, weight: .bold))
                .frame(width: PaneToolbarMetrics.control, height: PaneToolbarMetrics.control)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: PaneToolbarMetrics.control, height: PaneToolbarMetrics.control)
        .fixedSize()
        .buttonStyle(.plain)
        .foregroundStyle(chrome.symbol)
        .help("More")
        .accessibilityLabel("More")
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
                .padding(.leading, extensionButtonCount > 0 ? 4 : 0)
        }
    }

    private func closePane() {
        model.focusPane(tabID: driver.tabID)
        model.close(driver.tabID)
    }

    private func separatePane() {
        model.focusPane(tabID: driver.tabID)
        model.separate(tabID: driver.tabID)
    }

    private func swapThisPane() {
        model.focusPane(tabID: driver.tabID)
        model.swapPane(tabID: driver.tabID)
    }

    private func goForward() {
        model.focusPane(tabID: driver.tabID)
        tab?.goForward()
    }

    private func copyLink() {
        model.focusPane(tabID: driver.tabID)
        model.copyCurrentLink()
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
