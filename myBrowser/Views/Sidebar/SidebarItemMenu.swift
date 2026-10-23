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
                Button("New Folder") { onNewFolderInside() }
                moveMenu
                Divider()
                Button("Delete", role: .destructive) { model.delete(item.id) }
            } else if item.section == .tabs {
                Button("Rename…") { onRename() }
                Button("Pin") { model.pin(item.id) }
                Button("Add to Favorites") { model.addToFavorites(item.id) }
                Button("New Folder") { onNewFolderInside() }
                moveMenu
                if let url = link {
                    Button("Copy Link") { SidebarClipboard.copy(url) }
                }
                pictureInPictureButton
                Divider()
                Button("Close") { model.close(item.id) }
            } else {
                Button("Unpin") { model.unpin(item.id) }
                Button("Rename…") { onRename() }
                if model.isPinnedAway(item.id) {
                    Button("Replace Pinned URL with Current") {
                        model.replacePinnedURLWithCurrent(item.id)
                    }
                }
                Button("New Folder") { onNewFolderInside() }
                moveMenu
                if let url = link {
                    Button("Copy Link") { SidebarClipboard.copy(url) }
                }
                pictureInPictureButton
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

    @ViewBuilder
    private var pictureInPictureButton: some View {
        if let tab = model.tabs[item.id], tab.showsPictureInPictureButton {
            Button(tab.isPictureInPictureActive ? "Exit Picture in Picture" : "Enter Picture in Picture") {
                model.togglePictureInPicture(item.id)
            }
        }
    }

    private var link: URL? {
        SidebarTitle.link(for: item, tab: model.tabs[item.id])
    }
}
