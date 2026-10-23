import AppKit
import SwiftUI

/// Pinned sites and nested folders for one space.
struct PinnedTree: View, Equatable {
    var spaceID: UUID
    var parentID: UUID? = nil
    var depth: Int = 0
    var onRename: (SidebarItem) -> Void
    var onNewFolder: (UUID?) -> Void

    static func == (lhs: PinnedTree, rhs: PinnedTree) -> Bool {
        lhs.spaceID == rhs.spaceID && lhs.parentID == rhs.parentID && lhs.depth == rhs.depth
    }

    @Environment(BrowserModel.self) private var model

    var body: some View {
        let children = model.library.siblings(of: parentID, section: .pinned, in: spaceID).items
        VStack(alignment: .leading, spacing: 1) {
            if children.isEmpty, parentID == nil {
                EmptyPinned(spaceID: spaceID)
            }
            ForEach(children) { item in
                if item.isFolder {
                    folder(item)
                } else {
                    SidebarRow(
                        item: item,
                        depth: depth,
                        showsLoadedState: true,
                        onRename: { onRename(item) },
                        onNewFolderInside: { onNewFolder(item.parentID) }
                    )
                }
            }
        }
        .animation(SidebarMotion.row, value: children.map(\.id))
    }

    private func folder(_ item: SidebarItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            folderRow(item)
            if item.isExpanded {
                PinnedTree(
                    spaceID: spaceID,
                    parentID: item.id,
                    depth: depth + 1,
                    onRename: onRename,
                    onNewFolder: onNewFolder
                )
                .equatable()
                .transition(.opacity)
            }
        }
        .clipped()
        .animation(SidebarMotion.disclosure, value: item.isExpanded)
    }

    private func folderRow(_ item: SidebarItem) -> some View {
        FolderRow(
            item: item,
            depth: depth,
            onRename: { onRename(item) },
            onNewFolder: { onNewFolder(item.id) }
        )
    }
}

private struct EmptyPinned: View {
    var spaceID: UUID
    @State private var token = UUID()

    var body: some View {
        Text("Pinned tabs and folders appear here")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .sidebarDropTarget(.tail(spaceID: spaceID, section: .pinned, token: token))
    }
}

private struct FolderRow: View {
    var item: SidebarItem
    var depth: Int
    var onRename: () -> Void
    var onNewFolder: () -> Void

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @State private var hovering = false

    var body: some View {
        let title = item.title.isEmpty ? "Folder" : item.title
        let isSelected = model.sidebarFocusID == item.id
        let isEditing = interaction.editingID == item.id
        let leading = SidebarDropGeometry.rowLeading + CGFloat(depth) * SidebarDropGeometry.indent

        // A plain button, same as a site row. `onTapGesture` takes the mouse-down and the
        // row never starts a drag session, so a folder could not be moved.
        Button {
            guard !interaction.shouldIgnoreRowClick() else { return }
            model.focusSidebarItem(item.id)
            NSApp.keyWindow?.makeFirstResponder(nil)
            model.toggleExpanded(item.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .animation(SidebarMotion.disclosure, value: item.isExpanded)
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                if isEditing {
                    SidebarInlineField(itemID: item.id, title: item.title)
                } else {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, leading)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            interaction.editingID = item.id
        })
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            SidebarSelectionBackground(isSelected: isSelected, isHovering: hovering, isLoaded: false)
        }
        .onContinuousHover { phase in
            if interaction.draggingID == item.id { return }
            hovering = if case .active = phase { true } else { false }
        }
        .animation(SidebarMotion.row, value: hovering)
        .sidebarDragRow(item: item, depth: depth)
        .modifier(SidebarItemMenu(item: item, onRename: onRename, onNewFolderInside: onNewFolder))
        .accessibilityLabel(title)
        .accessibilityValue(item.isExpanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
    }
}
