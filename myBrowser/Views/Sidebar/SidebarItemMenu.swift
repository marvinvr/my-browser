import SwiftUI

/// Context menu for a sidebar item. Delete unloads the tab and fixes selection before the item is removed.
struct SidebarItemMenu: ViewModifier {
    var item: SidebarItem
    var onRename: () -> Void
    var onNewFolderInside: () -> Void

    @Environment(BrowserModel.self) private var model

    func body(content: Content) -> some View {
        content.contextMenu {
            if item.isFolder {
                Button("Rename") { onRename() }
                Button("New Folder") { onNewFolderInside() }
                moveMenu
                Divider()
                Button("Delete", role: .destructive) { model.delete(item.id) }
            } else if item.isSplit {
                if item.section == .tabs {
                    Button("Pin") { model.pin(item.id) }
                } else {
                    Button("Unpin") { model.unpin(item.id) }
                }
                moveMenu
                if let url = splitLink {
                    Button("Copy Link") { SidebarClipboard.copy(url) }
                }
                Divider()
                Button("Close") { model.close(item.id) }
                if item.section != .tabs {
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(item.id) }
                }
            } else if item.section == .tabs {
                Button("Pin") { model.pin(item.id) }
                Button("Add to Favorites") { model.addToFavorites(item.id) }
                Button("New Folder") { onNewFolderInside() }
                moveMenu
                if let url = link {
                    Button("Copy Link") { SidebarClipboard.copy(url) }
                }
                Divider()
                Button("Close") { model.close(item.id) }
            } else {
                Button("Unpin") { model.unpin(item.id) }
                Button("Rename") { onRename() }
                Button("New Folder") { onNewFolderInside() }
                moveMenu
                if let url = link {
                    Button("Copy Link") { SidebarClipboard.copy(url) }
                }
                Button("Close") { model.close(item.id) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(item.id) }
            }
        }
    }

    private var moveMenu: some View {
        Menu("Move to Space") {
            ForEach(model.library.orderedSpaces) { space in
                Button(space.name) {
                    let section = model.library.sectionForSpaceDrop(item)
                    model.moveItem(item.id, toSpace: space.id, section: section, parentID: nil, position: .end)
                }
                .disabled(space.id == item.spaceID)
            }
        }
    }

    private var link: URL? {
        SidebarTitle.link(for: item, tab: model.tabs[item.id])
    }

    /// Focused pane, or the first pane when focus has not been stored.
    private var splitLink: URL? {
        let members = model.library.splitMembers(of: item.id)
        let focus = model.resolvedFocus(in: item.id)
        guard let member = members.first(where: { $0.id == focus }) ?? members.first else { return nil }
        return SidebarTitle.link(for: member, tab: model.tabs[member.id])
    }
}
