import AppKit
import SwiftUI

/// Favorites for one space, four rounded tiles per row.
struct FavoritesGrid: View {
    var spaceID: UUID
    var onRename: (SidebarItem) -> Void
    var onNewFolder: () -> Void

    @Environment(BrowserModel.self) private var model
    @State private var emptyToken = UUID()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        let items = model.library.siblings(of: nil, section: .favorites, in: spaceID).items
        if items.isEmpty {
            Color.clear
                .frame(height: 12)
                .sidebarDropTarget(.tail(spaceID: spaceID, section: .favorites, token: emptyToken))
        } else {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(items) { item in
                    tile(item)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 2)
            .animation(SidebarMotion.row, value: items.map(\.id))
        }
    }

    private func tile(_ item: SidebarItem) -> some View {
        let tab = model.tabs[item.id]
        let title = SidebarTitle.text(for: item, tab: tab)
        let isSelected = model.selectedItemID == item.id
        let isLoaded = tab?.isLoaded == true
        let icon = tab?.favicon ?? item.url.flatMap { model.favicons.cachedFavicon(for: $0) }
        return FavoriteTile(
            item: item,
            title: title,
            favicon: icon,
            isSelected: isSelected,
            isLoaded: isLoaded,
            onRename: { onRename(item) },
            onNewFolder: onNewFolder
        )
    }
}

private struct FavoriteTile: View {
    var item: SidebarItem
    var title: String
    var favicon: NSImage?
    var isSelected: Bool
    var isLoaded: Bool
    var onRename: () -> Void
    var onNewFolder: () -> Void

    @State private var hovering = false

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction

    var body: some View {
        Button {
            model.select(item.id)
        } label: {
            Group {
                if interaction.editingID == item.id {
                    SidebarInlineField(itemID: item.id, title: item.title)
                        .padding(.horizontal, 4)
                } else {
                    FaviconView(image: favicon, url: item.url, title: title, size: 18)
                        .opacity(isLoaded || isSelected ? 1 : 0.72)
                }
            }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background {
                    SidebarSelectionBackground(
                        isSelected: isSelected,
                        isHovering: hovering,
                        isLoaded: isLoaded,
                        baseOpacity: 0.04,
                        loadedOpacity: 0.12
                    )
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            interaction.editingID = item.id
        })
        .help(title)
        .onContinuousHover { phase in
            if case .active = phase {
                hovering = true
            } else {
                hovering = false
            }
        }
        .sidebarDragRow(item: item, depth: 0, axis: .horizontal)
        .modifier(SidebarItemMenu(item: item, onRename: onRename, onNewFolderInside: onNewFolder))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
