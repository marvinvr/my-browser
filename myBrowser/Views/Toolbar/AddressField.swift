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

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var resolved: ToolbarChrome {
        chrome ?? ToolbarChrome.resolve(tint: model.selectedTab?.themeColor, colorScheme: colorScheme)
    }

    /// The top toolbar has no field at rest. Hover, focus, and Cmd+L draw a quiet one.
    private var showsInlineField: Bool {
        hovering || focused || model.commandBarMode == .editCurrent
    }

    /// `BrowserTab.url` is the observable value. `WKWebView.url` is not, so reading it
    /// alone leaves this text stuck after a navigation that does not retint the bar.
    private var pageURL: URL? {
        if let live = model.selectedTab?.url, BrowserTab.isPageURL(live) { return live }
        if let live = model.selectedTab?.webView?.url, BrowserTab.isPageURL(live) { return live }
        return model.selectedItemID.flatMap { model.library.item($0)?.url }
    }

    var body: some View {
        let display = URLDisplay.format(pageURL)
        let style = resolved
        let inline = presentation == .inline
        HStack(spacing: 4) {
            CopyLinkButton(chrome: style, quiet: inline)
            Button {
                model.showCommandBar(.editCurrent)
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

    private func insecureBadge(_ style: ToolbarChrome) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.slash")
                .font(.system(size: 10, weight: .semibold))
            Text("Not Secure")
                .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if display.isEmpty {
                Text("Search or enter URL")
                    .font(.system(size: 13, weight: .medium))
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
                part.font = .system(size: 13, weight: .medium)
            case .separator, .path, .ellipsis:
                part.foregroundColor = style.secondaryText
                part.font = .system(size: 13, weight: .regular)
            }
            line += part
        }
        return line
    }
}
