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
                splitMenu
            } else if item.section == .tabs {
                joinCommands
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
                joinCommands
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

    @ViewBuilder
    private var splitMenu: some View {
        if item.section == .tabs {
            Button("Pin") { model.pin(item.id) }
        } else {
            Button("Unpin") { model.unpin(item.id) }
        }
        moveMenu
        if let url = splitLink {
            Button("Copy Link") { SidebarClipboard.copy(url) }
        }
        let members = model.library.splitMembers(of: item.id)
        if !members.isEmpty {
            Divider()
            ForEach(members) { member in
                Menu(memberTitle(member)) {
                    Button("Separate") { model.separate(tabID: member.id) }
                    Button("Close") { model.close(member.id) }
                }
            }
            if members.count == 2 {
                Button("Swap Panes") { model.swapPanes(splitID: item.id, 0, 1) }
            }
            Button("Separate All") { model.separateAllPanes(of: item.id) }
        }
        Divider()
        Button("Close") { model.close(item.id) }
        if item.section != .tabs {
            Divider()
            Button("Delete", role: .destructive) { model.delete(item.id) }
        }
    }

    /// Pair this site with the selection, or offer recent tabs. A selected split offers Add instead.
    @ViewBuilder
    private var joinCommands: some View {
        if let split = model.selectedSplitToJoin(for: item.id) {
            Button("Add to Split View") {
                let index = model.library.splitMembers(of: split.id).count
                model.addToSplit(tabID: item.id, splitID: split.id, at: index)
            }
        } else if model.canStartSplit(from: item.id) {
            if let partner = model.selectedSplitPartner(for: item.id) {
                Button("Open in Split View") {
                    model.createSplit(tabIDs: [item.id, partner.id])
                }
            }
            let partners = model.recentSplitPartners(for: item.id)
            let titledAsPartnerMenu = model.selectedSplitPartner(for: item.id) != nil
            Menu(titledAsPartnerMenu ? "Open in Split View with" : "Open in Split View") {
                Button("New Tab") { model.openInSplitView(anchoredOn: item.id) }
                if !partners.isEmpty {
                    Divider()
                    ForEach(partners) { partner in
                        Button(memberTitle(partner)) {
                            model.createSplit(tabIDs: [item.id, partner.id])
                        }
                    }
                }
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

    private func memberTitle(_ member: SidebarItem) -> String {
        SidebarTitle.text(for: member, tab: model.tabs[member.id])
    }
}
