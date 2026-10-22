import AppKit
import SwiftUI

/// A site row shared by pinned items and today's tabs.
struct SidebarRow: View {
    var item: SidebarItem
    var depth: Int = 0
    var showsLoadedState: Bool = false
    var onRename: () -> Void
    var onNewFolderInside: () -> Void = {}

    @Environment(BrowserModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let tab = model.tabs[item.id]
        let title = SidebarTitle.text(for: item, tab: tab)
        let isSelected = model.selectedItemID == item.id
        let isLoaded = tab?.isLoaded == true
        let icon = tab?.favicon ?? (item.url ?? tab?.url).flatMap { model.favicons.cachedFavicon(for: $0) }

        HStack(spacing: 0) {
            Button {
                model.select(item.id)
            } label: {
                HStack(spacing: 8) {
                    FaviconView(image: icon, url: item.url ?? tab?.url, title: title, size: 16)
                        .opacity(isLoaded || isSelected ? 1 : 0.78)
                    FlatLabel(text: title)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6 + CGFloat(depth) * 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                Button {
                    model.close(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
                .transition(.opacity)
                .accessibilityLabel("Close \(title)")
            }
        }
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovering: hovering,
                isLoaded: showsLoadedState && isLoaded
            )
        }
        .onContinuousHover { phase in
            if case .active = phase {
                hovering = true
            } else {
                hovering = false
            }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_HOVER"] == "1", isSelected {
                hovering = true
            }
            #endif
        }
        .animation(SidebarMotion.selection, value: hovering)
        .modifier(SidebarItemMenu(item: item, onRename: onRename, onNewFolderInside: onNewFolderInside))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Opaque sidebar title. Vibrant `Text` over the selection fill cache-displays as grey and
/// washes out against the light-mode chip.
private struct FlatLabel: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> FlatLabelField {
        let field = FlatLabelField(frame: .zero)
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.stringValue = text
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return field
    }

    func updateNSView(_ field: FlatLabelField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.textColor = .labelColor
    }
}

private final class FlatLabelField: NSTextField {
    override var allowsVibrancy: Bool { false }
}
