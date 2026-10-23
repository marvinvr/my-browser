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
                splitSegments(isSelected: isSelected)
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
                        .frame(width: SidebarMetrics.closeHit, height: SidebarMetrics.rowHeight)
                        .padding(.trailing, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .opacity(interaction.draggingID == nil ? 1 : 0)
                .allowsHitTesting(interaction.draggingID == nil)
                .accessibilityHidden(interaction.draggingID != nil)
                .accessibilityLabel("Close \(closeTitle)")
            }
        }
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            // A split's fill sits on the focused segment, not across the whole row.
            if !item.isSplit {
                SidebarSelectionBackground(
                    isSelected: isSelected,
                    isHovering: hovering
                )
            }
        }
        // The pill is the hit target: padding, the icon gap, and the empty trailing side.
        .contentShape(Rectangle())
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
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One row-height container. Segments share its width; a gap separates them.
    /// Folder depth indents the container the same way a nested site row indents its icon.
    private func splitSegments(isSelected: Bool) -> some View {
        let members = model.library.splitMembers(of: item.id)
        let focusID = model.resolvedFocus(in: item.id)
        return SplitSegmentLayout(spacing: SidebarMetrics.splitSegmentGap) {
            ForEach(members) { member in
                SplitPaneSegment(
                    member: member,
                    splitID: item.id,
                    focused: member.id == focusID,
                    rowSelected: isSelected,
                    paneCount: members.count
                )
            }
        }
        .padding(.leading, CGFloat(depth) * SidebarDropGeometry.indent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

/// One pane inside a split row. Same height and corner radius as a site row.
/// The focused pane of the selected split takes the selection fill; hover fills just this segment.
private struct SplitPaneSegment: View {
    var member: SidebarItem
    var splitID: UUID
    var focused: Bool
    var rowSelected: Bool
    var paneCount: Int

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let showTitle = SidebarMetrics.splitSegmentShowsTitle(paneCount: paneCount, width: geo.size.width)
            segment(showTitle: showTitle)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SidebarSelectionBackground(
                isSelected: rowSelected && focused,
                isHovering: hovering
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if interaction.draggingID == splitID { return }
            hovering = if case .active = phase { true } else { false }
        }
    }

    private func segment(showTitle: Bool) -> some View {
        let tab = model.tabs[member.id]
        let away = model.isPinnedAway(member.id)
        let title = SidebarTitle.text(for: member, tab: tab)
        let icon = iconImage(tab: tab, away: away)
        let iconURL = member.section == .tabs ? (member.url ?? tab?.url) : member.url
        return HStack(spacing: 0) {
            iconControl(
                image: icon,
                url: iconURL,
                title: title,
                away: away,
                fills: !showTitle,
                leading: showTitle ? SidebarDropGeometry.rowLeading : 0,
                trailing: showTitle ? 8 : 0
            )
            if showTitle {
                titleControl(title: title, away: away, trailing: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The icon returns a pin home when the live page has moved. The rest of the segment focuses the pane.
    private func iconControl(
        image: NSImage?,
        url: URL?,
        title: String,
        away: Bool,
        fills: Bool,
        leading: CGFloat,
        trailing: CGFloat
    ) -> some View {
        Button {
            guard !interaction.shouldIgnoreRowClick() else { return }
            if away {
                model.returnToPinnedURL(member.id)
            } else {
                model.select(member.id)
            }
        } label: {
            FaviconView(image: image, url: url, title: title, size: SidebarMetrics.rowIcon)
                .frame(maxWidth: fills ? .infinity : nil, maxHeight: .infinity)
                .padding(.leading, leading)
                .padding(.trailing, trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: fills ? .infinity : nil, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .accessibilityHidden(!fills)
        .accessibilityAddTraits(fills && rowSelected && focused ? .isSelected : [])
    }

    private func titleControl(title: String, away: Bool, trailing: CGFloat) -> some View {
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
                FlatLabel(text: title)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, trailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(rowSelected && focused ? .isSelected : [])
    }

    private func iconImage(tab: BrowserTab?, away: Bool) -> NSImage? {
        if away, let saved = member.url, let cached = model.favicons.cachedFavicon(for: saved) {
            return cached
        }
        return tab?.favicon ?? (member.url ?? tab?.url).flatMap { model.favicons.cachedFavicon(for: $0) }
    }
}

/// Equal slots for a split row. Title length does not change a segment's width.
private nonisolated struct SplitSegmentLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: proposal.width ?? 0,
            height: proposal.height ?? SidebarMetrics.rowHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let gaps = spacing * CGFloat(count - 1)
        let width = max(0, (bounds.width - gaps) / CGFloat(count))
        let child = ProposedViewSize(width: width, height: bounds.height)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: child)
            x += width + spacing
        }
    }
}

/// Opaque sidebar title. Vibrant `Text` over the selection fill cache-displays as grey and
/// washes out against the light-mode chip.
private struct FlatLabel: NSViewRepresentable {
    enum Prominence {
        /// A row title. Split panes use this too; the segment fill marks focus.
        case regular
        /// The away slash.
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

    /// The field is only a title. A hit here never reaches the row button, so the
    /// first click looks dead and a second click is required.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
