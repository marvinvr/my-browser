import SwiftUI

/// Pinned sites and nested folders for one space.
struct PinnedTree: View {
    var spaceID: UUID
    var parentID: UUID? = nil
    var depth: Int = 0
    var onRename: (SidebarItem) -> Void
    var onNewFolder: (UUID?) -> Void

    @Environment(BrowserModel.self) private var model

    var body: some View {
        let children = model.library.children(of: parentID, section: .pinned, in: spaceID)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(children) { item in
                if item.isFolder {
                    folder(item)
                } else {
                    SidebarRow(
                        item: item,
                        depth: depth,
                        showsLoadedState: true,
                        onRename: { onRename(item) },
                        onNewFolderInside: { onNewFolder(item.id) }
                    )
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
        }
        .animation(SidebarMotion.list, value: children.map(\.id))
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
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(SidebarMotion.list, value: item.isExpanded)
    }

    private func folderRow(_ item: SidebarItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
                .frame(width: 12, height: 12)
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(item.title.isEmpty ? "Folder" : item.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 8)
        .frame(height: SidebarMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.toggleExpanded(item.id) }
        .modifier(SidebarItemMenu(
            item: item,
            onRename: { onRename(item) },
            onNewFolderInside: { onNewFolder(item.id) }
        ))
        .accessibilityLabel(item.title.isEmpty ? "Folder" : item.title)
        .accessibilityValue(item.isExpanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
    }
}
