import SwiftUI

/// Address field: copy button, optional insecure warning, then `URLDisplay`.
///
/// `.pill` is the sidebar address bar: a capsule on neutral chrome. `.inline` is the top
/// toolbar: plain secondary text, no site colour behind the URL, and a neutral field only
/// while hovering, focused, or editing. A click opens the command bar in edit-current mode.
struct AddressField: View {
    enum Presentation: Equatable {
        case pill
        case inline
    }

    var chrome: ToolbarChrome? = nil
    var presentation: Presentation = .pill
    /// Set on a split pane. Nil follows the selected tab, which is the shared toolbar.
    var tabID: UUID? = nil

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var boundTab: BrowserTab? {
        if let tabID { return model.tabs[tabID] }
        return model.selectedTab
    }

    private var resolved: ToolbarChrome {
        chrome ?? ToolbarChrome.resolve(tint: boundTab?.themeColor, colorScheme: colorScheme)
    }

    /// The top toolbar has no field at rest. Hover, focus, and Cmd+L draw a quiet one.
    /// A pane field lights up for Cmd+L only while that pane is the selected one.
    private var showsInlineField: Bool {
        hovering || focused || editingThisField
    }

    private var editingThisField: Bool {
        guard model.commandBarMode == .editCurrent else { return false }
        if let tabID { return model.selectedTab?.id == tabID }
        return true
    }

    /// `BrowserTab.url` is the observable value. `WKWebView.url` is not, so reading it
    /// alone leaves this text stuck after a navigation that does not retint the bar.
    private var pageURL: URL? {
        if let live = boundTab?.url, BrowserTab.isPageURL(live) { return live }
        if let live = boundTab?.webView?.url, BrowserTab.isPageURL(live) { return live }
        if let tabID { return model.library.item(tabID)?.url }
        return model.selectedItemID.flatMap { model.library.item($0)?.url }
    }

    var body: some View {
        let display = URLDisplay.format(pageURL)
        let style = resolved
        let inline = presentation == .inline
        HStack(spacing: 4) {
            CopyLinkButton(chrome: style, quiet: inline, tabID: tabID)
            siteInfoButton(style, quiet: inline)
            Button {
                if let tabID {
                    model.focusPane(tabID: tabID)
                    model.presentCommandBar(.editCurrent)
                } else {
                    model.showCommandBar(.editCurrent)
                }
            } label: {
                HStack(spacing: 6) {
                    if display.security == .insecure {
                        insecureBadge(style)
                    }
                    addressLabel(display, style: style)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .help("Edit Address")
        }
        .padding(.leading, inline ? 6 : 3)
        .padding(.trailing, inline ? 8 : 12)
        .frame(height: SidebarMetrics.toolbarControl)
        .background { fieldFill(style) }
        .overlay { fieldStroke(style) }
        .onHover { hovering = $0 }
        .animation(inline ? .easeOut(duration: 0.15) : nil, value: showsInlineField)
        .popover(isPresented: notificationPromptPresented, arrowEdge: .top) {
            if let prompt = model.notifications.prompt {
                NotificationPermissionBubble(host: prompt.host) {
                    model.notifications.choose(allow: true)
                } onDeny: {
                    model.notifications.choose(allow: false)
                }
                .presentationBackground(Color(nsColor: .windowBackgroundColor))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address")
        .accessibilityValue(display.isEmpty ? "Search or enter URL" : display.absolute)
    }

    @ViewBuilder
    private func fieldFill(_ style: ToolbarChrome) -> some View {
        if presentation == .pill {
            Capsule().fill(style.field)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(showsInlineField ? inlineFill : 0))
        }
    }

    @ViewBuilder
    private func fieldStroke(_ style: ToolbarChrome) -> some View {
        if presentation == .pill {
            Capsule().strokeBorder(style.stroke, lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(showsInlineField ? inlineStroke : 0), lineWidth: 0.5)
        }
    }

    /// Barely there. Light and dark stay neutral; the page tint never fills this shape.
    private var inlineFill: Double { colorScheme == .dark ? 0.08 : 0.05 }
    private var inlineStroke: Double { colorScheme == .dark ? 0.12 : 0.07 }

    private var notificationOrigin: String? {
        guard let pageURL else { return nil }
        return NotificationOrigin.key(for: pageURL)
    }

    /// Outside a click does not answer the page. Allow and Don't Allow do.
    private var notificationPromptPresented: Binding<Bool> {
        Binding(
            get: {
                guard let prompt = model.notifications.prompt else { return false }
                let owner = tabID ?? model.selectedTab?.id
                if let promptTab = prompt.tabID, promptTab != owner { return false }
                return true
            },
            set: { _ in }
        )
    }

    @ViewBuilder
    private func siteInfoButton(_ style: ToolbarChrome, quiet: Bool) -> some View {
        if let origin = notificationOrigin, let profileID = boundTab?.profileID ?? model.selectedSpace?.profileID {
            let choice = model.notifications.siteChoice(profileID: profileID, origin: origin)
            Menu {
                Text(NotificationOrigin.displayHost(origin))
                if pageURL?.scheme?.lowercased() == "http" {
                    Text("Not Secure")
                }
                Picker("Notifications", selection: siteChoice(profileID: profileID, origin: origin)) {
                    ForEach(NotificationSiteChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            } label: {
                Image(systemName: siteSymbol(choice: choice, secure: pageURL?.scheme?.lowercased() == "https"))
                    .font(.system(size: SidebarMetrics.addressSymbol, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.plain)
            .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(style.fieldSymbol))
            .help("Site Settings")
            .accessibilityLabel("Site Settings")
            .accessibilityIdentifier("site-info")
        }
    }

    private func siteSymbol(choice: NotificationSiteChoice, secure: Bool) -> String {
        switch choice {
        case .allow: "bell"
        case .block: "bell.slash"
        case .ask: secure ? "lock" : "lock.slash"
        }
    }

    private func siteChoice(profileID: UUID, origin: String) -> Binding<NotificationSiteChoice> {
        Binding(
            get: { model.notifications.siteChoice(profileID: profileID, origin: origin) },
            set: { model.notifications.setSiteChoice(profileID: profileID, origin: origin, choice: $0) }
        )
    }

    private func insecureBadge(_ style: ToolbarChrome) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.slash")
                .font(.system(size: SidebarMetrics.addressWarningSymbol, weight: .semibold))
            Text("Not Secure")
                .font(.system(size: SidebarMetrics.addressWarningText, weight: .medium))
        }
        .foregroundStyle(presentation == .inline ? AnyShapeStyle(Color.orange) : AnyShapeStyle(style.warning))
        .symbolRenderingMode(.monochrome)
        .fixedSize()
        .help("Not Secure")
        .accessibilityLabel("Not Secure")
    }

    private func addressLabel(_ display: URLDisplay, style: ToolbarChrome) -> some View {
        Group {
            if presentation == .inline {
                Text(display.isEmpty ? "Search or enter URL" : display.plainText)
                    .font(.system(size: SidebarMetrics.addressText, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if display.isEmpty {
                Text("Search or enter URL")
                    .font(.system(size: SidebarMetrics.addressText, weight: .medium))
                    .foregroundStyle(style.secondaryText)
            } else {
                Text(attributed(display, style: style))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: presentation == .pill ? .infinity : nil, alignment: .leading)
    }

    private func attributed(_ display: URLDisplay, style: ToolbarChrome) -> AttributedString {
        var line = AttributedString()
        for piece in display.pieces {
            var part = AttributedString(piece.text)
            switch piece.kind {
            case .host:
                part.foregroundColor = style.primaryText
                part.font = .system(size: SidebarMetrics.addressText, weight: .medium)
            case .separator, .path, .ellipsis:
                part.foregroundColor = style.secondaryText
                part.font = .system(size: SidebarMetrics.addressText, weight: .regular)
            }
            line += part
        }
        return line
    }
}
