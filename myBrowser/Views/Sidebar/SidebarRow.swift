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
        let away = model.isPinnedAway(item.id)
        let title = SidebarTitle.text(for: item, tab: tab)
        let isSelected = model.selectedItemID == item.id && !model.sidebarFocusIsFolder
        let isEditing = interaction.editingID == item.id
        let icon = rowIcon(tab: tab, away: away)
        let leading = SidebarDropGeometry.rowLeading + CGFloat(depth) * SidebarDropGeometry.indent
        let iconURL = item.section == .tabs ? (item.url ?? tab?.url) : item.url

        HStack(spacing: 0) {
            if item.section == .pinned {
                Button {
                    if away {
                        model.returnToPinnedURL(item.id)
                    } else {
                        model.select(item.id)
                    }
                } label: {
                    FaviconView(image: icon, url: iconURL, title: title, size: 16)
                        .padding(.leading, leading)
                        .padding(.trailing, away && !isEditing ? 0 : 8)
                        .frame(height: SidebarMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

            if isEditing {
                HStack(spacing: item.section == .pinned ? 0 : 8) {
                    if item.section != .pinned {
                        FaviconView(image: icon, url: iconURL, title: title, size: 16)
                    }
                    SidebarInlineField(title: title, itemID: item.id)
                    Spacer(minLength: 0)
                }
                .padding(.leading, item.section == .pinned ? 0 : leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    model.select(item.id)
                } label: {
                    HStack(spacing: item.section == .pinned ? 0 : 8) {
                        if item.section != .pinned {
                            FaviconView(image: icon, url: iconURL, title: title, size: 16)
                        }
                        if away {
                            FlatLabel(text: "  /  ", color: .secondaryLabelColor, hugs: true)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityHidden(true)
                        }
                        FlatLabel(text: title)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, item.section == .pinned ? 0 : leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

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

    /// Away pins keep the saved site's icon. The slash is what says the page has moved.
    private func rowIcon(tab: BrowserTab?, away: Bool) -> NSImage? {
        if away, let saved = item.url, let cached = model.favicons.cachedFavicon(for: saved) {
            return cached
        }
        return tab?.favicon ?? (item.url ?? tab?.url).flatMap { model.favicons.cachedFavicon(for: $0) }
    }
}

/// Opaque sidebar title. Vibrant `Text` over the selection fill cache-displays as grey and
/// washes out against the light-mode chip.
private struct FlatLabel: NSViewRepresentable {
    var text: String
    var color: NSColor = .labelColor
    var hugs: Bool = false

    func makeNSView(context: Context) -> FlatLabelField {
        let field = FlatLabelField(frame: .zero)
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.stringValue = text
        field.wantsLayer = true
        field.layerContentsRedrawPolicy = .onSetNeedsDisplay
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        applyHugging(field)
        return field
    }

    func updateNSView(_ field: FlatLabelField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.textColor = color
        applyHugging(field)
    }

    private func applyHugging(_ field: FlatLabelField) {
        let priority: NSLayoutConstraint.Priority = hugs ? .required : .defaultLow
        field.setContentCompressionResistancePriority(priority, for: .horizontal)
        field.setContentHuggingPriority(hugs ? .required : .defaultLow, for: .horizontal)
    }
}

private final class FlatLabelField: NSTextField {
    override var allowsVibrancy: Bool { false }
}
