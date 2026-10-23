import AppKit
import SwiftUI

/// A site or split row shared by pinned items and today's tabs.
struct SidebarRow: View {
    var item: SidebarItem
    var depth: Int = 0
    var onRename: () -> Void
    var onNewFolderInside: () -> Void = {}

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @State private var hovering = false

    var body: some View {
        let isSelected = model.selectedItemID == item.id && !model.sidebarFocusIsFolder
        let isEditing = interaction.editingID == item.id && !item.isSplit
        let leading = SidebarDropGeometry.rowLeading + CGFloat(depth) * SidebarDropGeometry.indent

        HStack(spacing: 0) {
            if item.isSplit {
                splitSegments(leading: leading, isSelected: isSelected)
            } else {
                siteControls(isEditing: isEditing, leading: leading)
            }

            if hovering, !isEditing {
                Button {
                    model.close(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: SidebarMetrics.closeGlyph, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: SidebarMetrics.closeHit, height: SidebarMetrics.closeHit)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.isSplit ? splitAccessibilityLabel : siteTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A pinned site puts the icon on its own button so a click returns home while the title stays on the live page.
    private func siteControls(isEditing: Bool, leading: CGFloat) -> some View {
        let tab = model.tabs[item.id]
        let away = model.isPinnedAway(item.id)
        let title = SidebarTitle.text(for: item, tab: tab)
        let icon = rowIcon(for: item, tab: tab, away: away)
        let iconURL = item.section == .tabs ? (item.url ?? tab?.url) : item.url
        return HStack(spacing: 0) {
            if item.section == .pinned {
                Button {
                    guard !interaction.shouldIgnoreRowClick() else { return }
                    if away {
                        model.returnToPinnedURL(item.id)
                    } else {
                        model.select(item.id)
                    }
                } label: {
                    FaviconView(image: icon, url: iconURL, title: title, size: SidebarMetrics.rowIcon)
                        .padding(.leading, leading)
                        .padding(.trailing, away && !isEditing ? 0 : 8)
                        .frame(height: SidebarMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

            Button {
                guard !interaction.shouldIgnoreRowClick() else { return }
                model.select(item.id)
            } label: {
                HStack(spacing: item.section == .pinned ? 0 : 8) {
                    if item.section != .pinned {
                        FaviconView(image: icon, url: iconURL, title: title, size: SidebarMetrics.rowIcon)
                    }
                    if away, !isEditing {
                        FlatLabel(text: "  /  ", prominence: .quiet, hugs: true)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityHidden(true)
                    }
                    if isEditing {
                        SidebarInlineField(title: item.title, itemID: item.id)
                    } else {
                        FlatLabel(text: title)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, item.section == .pinned ? 0 : leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func splitSegments(leading: CGFloat, isSelected: Bool) -> some View {
        let members = model.library.splitMembers(of: item.id)
        let focusID = model.resolvedFocus(in: item.id)
        return HStack(spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(isSelected ? 0.28 : 0.16))
                        .frame(width: 1, height: SidebarMetrics.splitDivider)
                        .padding(.horizontal, 4)
                        .accessibilityHidden(true)
                }
                splitSegment(member, focused: member.id == focusID)
            }
        }
        .padding(.leading, leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func splitSegment(_ member: SidebarItem, focused: Bool) -> some View {
        let tab = model.tabs[member.id]
        let away = model.isPinnedAway(member.id)
        let title = SidebarTitle.text(for: member, tab: tab)
        let icon = rowIcon(for: member, tab: tab, away: away)
        let iconURL = member.section == .tabs ? (member.url ?? tab?.url) : member.url
        return HStack(spacing: 0) {
            Button {
                guard !interaction.shouldIgnoreRowClick() else { return }
                if away {
                    model.returnToPinnedURL(member.id)
                } else {
                    model.select(member.id)
                }
            } label: {
                FaviconView(image: icon, url: iconURL, title: title, size: SidebarMetrics.rowIcon)
                    .frame(height: SidebarMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            Button {
                guard !interaction.shouldIgnoreRowClick() else { return }
                model.select(member.id)
            } label: {
                HStack(spacing: 0) {
                    if away {
                        FlatLabel(text: "  /  ", prominence: .quiet, hugs: true)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityHidden(true)
                    }
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
    }

    /// Away pins keep the saved site's icon. The slash is what says the page has moved.
    private func rowIcon(for item: SidebarItem, tab: BrowserTab?, away: Bool) -> NSImage? {
        if away, let saved = item.url, let cached = model.favicons.cachedFavicon(for: saved) {
            return cached
        }
        return tab?.favicon ?? (item.url ?? tab?.url).flatMap { model.favicons.cachedFavicon(for: $0) }
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
        /// An unfocused pane in a split row, and the away slash.
        case quiet
    }

    var text: String
    var prominence: Prominence = .regular
    var hugs: Bool = false

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
            field.font = .systemFont(ofSize: SidebarMetrics.rowTitle)
            field.textColor = .labelColor
        case .strong:
            field.font = .systemFont(ofSize: SidebarMetrics.rowTitle, weight: .medium)
            field.textColor = .labelColor
        case .quiet:
            field.font = .systemFont(ofSize: SidebarMetrics.rowTitle)
            field.textColor = .secondaryLabelColor
        }
        let priority: NSLayoutConstraint.Priority = hugs ? .required : .defaultLow
        field.setContentCompressionResistancePriority(priority, for: .horizontal)
        field.setContentHuggingPriority(hugs ? .required : .defaultLow, for: .horizontal)
    }
}

private final class FlatLabelField: NSTextField {
    override var allowsVibrancy: Bool { false }
}
