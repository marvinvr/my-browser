import AppKit
import SwiftUI

/// A site or split row shared by pinned items and today's tabs.
struct SidebarRow: View {
    var item: SidebarItem
    var depth: Int = 0
    var showsLoadedState: Bool = false
    var onRename: () -> Void
    var onNewFolderInside: () -> Void = {}

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @State private var hovering = false

    var body: some View {
        let isSelected = model.selectedItemID == item.id && !model.sidebarFocusIsFolder
        let isEditing = interaction.editingID == item.id && item.section != .tabs && !item.isSplit
        let isLoaded = showsLoadedState && loaded
        let leading = SidebarDropGeometry.rowLeading + CGFloat(depth) * SidebarDropGeometry.indent

        HStack(spacing: 0) {
            if item.isSplit {
                splitSegments(leading: leading, isSelected: isSelected)
            } else {
                siteButton(title: siteTitle, isSelected: isSelected, isEditing: isEditing, leading: leading)
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
                .accessibilityLabel("Close \(closeTitle)")
            }
        }
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovering: hovering,
                isLoaded: isLoaded
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.isSplit ? splitAccessibilityLabel : siteTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func siteButton(title: String, isSelected: Bool, isEditing: Bool, leading: CGFloat) -> some View {
        let tab = model.tabs[item.id]
        let icon = tab?.favicon ?? (item.url ?? tab?.url).flatMap { model.favicons.cachedFavicon(for: $0) }
        return Button {
            model.select(item.id)
        } label: {
            HStack(spacing: 8) {
                FaviconView(image: icon, url: item.url ?? tab?.url, title: title, size: 16)
                    .opacity(tab?.isLoaded == true || isSelected ? 1 : 0.78)
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
    }

    private func splitSegments(leading: CGFloat, isSelected: Bool) -> some View {
        let members = model.library.splitMembers(of: item.id)
        let focusID = model.resolvedFocus(in: item.id)
        return HStack(spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(isSelected ? 0.28 : 0.16))
                        .frame(width: 1, height: 12)
                        .padding(.horizontal, 4)
                        .accessibilityHidden(true)
                }
                splitSegment(member, focused: member.id == focusID, rowSelected: isSelected)
            }
        }
        .padding(.leading, leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func splitSegment(_ member: SidebarItem, focused: Bool, rowSelected: Bool) -> some View {
        let tab = model.tabs[member.id]
        let title = SidebarTitle.text(for: member, tab: tab)
        let icon = tab?.favicon ?? (member.url ?? tab?.url).flatMap { model.favicons.cachedFavicon(for: $0) }
        return Button {
            guard !interaction.shouldIgnoreRowClick() else { return }
            model.select(member.id)
        } label: {
            HStack(spacing: 5) {
                FaviconView(image: icon, url: member.url ?? tab?.url, title: title, size: 16)
                    .opacity(tab?.isLoaded == true || focused || rowSelected ? 1 : 0.78)
                FlatLabel(text: title, prominence: focused ? .strong : .quiet)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }

    /// The open tab keeps its loaded wash. A split uses the focused pane.
    private var loaded: Bool {
        if item.isSplit {
            guard let focus = model.resolvedFocus(in: item.id) else { return false }
            return model.tabs[focus]?.isLoaded == true
        }
        return model.tabs[item.id]?.isLoaded == true
    }

    private var siteTitle: String {
        SidebarTitle.text(for: item, tab: model.tabs[item.id])
    }

    private var closeTitle: String {
        guard item.isSplit else { return siteTitle }
        let members = model.library.splitMembers(of: item.id)
        let focus = model.resolvedFocus(in: item.id)
        guard let member = members.first(where: { $0.id == focus }) ?? members.first else { return siteTitle }
        return SidebarTitle.text(for: member, tab: model.tabs[member.id])
    }

    private var splitAccessibilityLabel: String {
        let titles = model.library.splitMembers(of: item.id).map { member in
            SidebarTitle.text(for: member, tab: model.tabs[member.id])
        }
        guard !titles.isEmpty else { return "Split view" }
        return "Split view, " + titles.joined(separator: ", ")
    }
}

/// Opaque sidebar title. Vibrant `Text` over the selection fill cache-displays as grey and
/// washes out against the light-mode chip.
private struct FlatLabel: NSViewRepresentable {
    enum Prominence {
        /// A normal row, and an unfocused split pane.
        case regular
        /// The focused pane. Slightly heavier than its siblings.
        case strong
        /// An unfocused pane in a split row.
        case quiet
    }

    var text: String
    var prominence: Prominence = .regular

    func makeNSView(context: Context) -> FlatLabelField {
        let field = FlatLabelField(frame: .zero)
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.stringValue = text
        field.wantsLayer = true
        field.layerContentsRedrawPolicy = .onSetNeedsDisplay
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        apply(to: field)
        return field
    }

    func updateNSView(_ field: FlatLabelField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        apply(to: field)
    }

    private func apply(to field: FlatLabelField) {
        switch prominence {
        case .regular:
            field.font = .systemFont(ofSize: 13)
            field.textColor = .labelColor
        case .strong:
            field.font = .systemFont(ofSize: 13, weight: .medium)
            field.textColor = .labelColor
        case .quiet:
            field.font = .systemFont(ofSize: 13)
            field.textColor = .secondaryLabelColor
        }
    }
}

private final class FlatLabelField: NSTextField {
    override var allowsVibrancy: Bool { false }
}
