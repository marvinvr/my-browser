import AppKit
import SwiftUI

/// Favorites for one space, four rounded tiles per row.
struct FavoritesGrid: View {
    var spaceID: UUID
    var onRename: (SidebarItem) -> Void

    @Environment(BrowserModel.self) private var model

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        let items = model.library.children(of: nil, section: .favorites, in: spaceID)
        if !items.isEmpty {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(items) { item in
                    tile(item)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 2)
            .animation(SidebarMotion.list, value: items.map(\.id))
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
            onRename: { onRename(item) }
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

    @State private var hovering = false

    @Environment(BrowserModel.self) private var model

    var body: some View {
        Button {
            model.select(item.id)
        } label: {
            FaviconView(image: favicon, url: item.url, title: title, size: 18)
                .opacity(isLoaded || isSelected ? 1 : 0.72)
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
        .help(title)
        .onContinuousHover { phase in
            if case .active = phase {
                hovering = true
            } else {
                hovering = false
            }
        }
        .modifier(SidebarItemMenu(item: item, onRename: onRename, onNewFolderInside: {}))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
