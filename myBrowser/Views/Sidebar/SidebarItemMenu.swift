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
                Button("Rename…") { onRename() }
                Button("New Folder inside") { onNewFolderInside() }
                Divider()
                Button("Delete", role: .destructive) { model.delete(item.id) }
            } else if item.section == .tabs {
                Button("Pin") { model.pin(item.id) }
                Button("Add to Favorites") { model.addToFavorites(item.id) }
                if let url = link {
                    Button("Copy Link") { SidebarClipboard.copy(url) }
                }
                Divider()
                Button("Close") { model.close(item.id) }
            } else {
                Button("Unpin") { model.unpin(item.id) }
                Button("Rename…") { onRename() }
                if let url = link {
                    Button("Copy Link") { SidebarClipboard.copy(url) }
                }
                Button("Close") { model.close(item.id) }
                Divider()
                Button("Delete", role: .destructive) { model.delete(item.id) }
            }
        }
    }

    private var link: URL? {
        SidebarTitle.link(for: item, tab: model.tabs[item.id])
    }
}
