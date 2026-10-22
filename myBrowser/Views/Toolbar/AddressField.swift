import SwiftUI

/// Rounded address field: copy button, optional insecure warning, then `URLDisplay`.
///
/// A click opens the command bar in edit-current mode (the full URL, selected). The formatted
/// line is only the resting state. `chrome` overrides the tint taken from the selected tab.
struct AddressField: View {
    var chrome: ToolbarChrome? = nil

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var resolved: ToolbarChrome {
        chrome ?? ToolbarChrome.resolve(tint: model.selectedTab?.themeColor, colorScheme: colorScheme)
    }

    private var pageURL: URL? {
        if let live = model.selectedTab?.webView?.url, BrowserTab.isPageURL(live) { return live }
        if let url = model.selectedTab?.url { return url }
        return model.selectedItemID.flatMap { model.library.item($0)?.url }
    }

    var body: some View {
        let display = URLDisplay.format(pageURL)
        let style = resolved
        HStack(spacing: 4) {
            CopyLinkButton(chrome: style)
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
            .help("Edit Address")
        }
        .padding(.leading, 3)
        .padding(.trailing, 12)
        .frame(height: SidebarMetrics.toolbarControl)
        .background {
            Capsule().fill(style.field)
        }
        .overlay {
            Capsule().strokeBorder(style.stroke, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address")
        .accessibilityValue(display.isEmpty ? "Search or enter URL" : display.absolute)
    }

    private func insecureBadge(_ style: ToolbarChrome) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.slash")
                .font(.system(size: 10, weight: .semibold))
            Text("Not Secure")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(style.warning)
        .symbolRenderingMode(.monochrome)
        .fixedSize()
        .help("Not Secure")
        .accessibilityLabel("Not Secure")
    }

    private func addressLabel(_ display: URLDisplay, style: ToolbarChrome) -> some View {
        Group {
            if display.isEmpty {
                Text("Search or enter URL")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(style.secondaryText)
            } else {
                Text(attributed(display, style: style))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
