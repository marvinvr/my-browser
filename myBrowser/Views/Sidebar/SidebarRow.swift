import AppKit
import SwiftUI

/// A site row shared by pinned items and today's tabs.
struct SidebarRow: View {
    var item: SidebarItem
    var depth: Int = 0
    var onRename: () -> Void
    var onNewFolderInside: () -> Void = {}

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @State private var hovering = false

    var body: some View {
        let tab = model.tabs[item.id]
        let title = SidebarTitle.text(for: item, tab: tab)
        let isSelected = model.selectedItemID == item.id && !model.sidebarFocusIsFolder
        let isEditing = interaction.editingID == item.id && item.section != .tabs
        let icon = tab?.favicon ?? (item.url ?? tab?.url).flatMap { model.favicons.cachedFavicon(for: $0) }
        let leading = SidebarDropGeometry.rowLeading + CGFloat(depth) * SidebarDropGeometry.indent

        HStack(spacing: 0) {
            Button {
                model.select(item.id)
            } label: {
                HStack(spacing: 8) {
                    FaviconView(image: icon, url: item.url ?? tab?.url, title: title, size: 16)
                    if isEditing {
                        SidebarInlineField(itemID: item.id, title: item.title)
                    } else {
                        FlatLabel(text: title)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard item.section != .tabs else { return }
                interaction.editingID = item.id
            })

            if hovering, !isEditing {
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
                .opacity(interaction.draggingID == nil ? 1 : 0)
                .allowsHitTesting(interaction.draggingID == nil)
                .accessibilityHidden(interaction.draggingID != nil)
                .accessibilityLabel("Close \(title)")
            }
        }
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovering: hovering
            )
        }
        .onContinuousHover { phase in
            if interaction.draggingID == item.id { return }
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
        .animation(SidebarMotion.row, value: hovering)
        .sidebarDragRow(item: item, depth: depth)
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
        field.wantsLayer = true
        field.layerContentsRedrawPolicy = .onSetNeedsDisplay
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
