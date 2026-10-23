import AppKit
import SwiftUI

/// How many favorites sit on each row. Rows are balanced for the width instead of filled left to right.
nonisolated enum FavoriteGridLayout {
    static let spacing: CGFloat = 6
    static let tileHeight: CGFloat = 36
    /// Smallest tile. The sidebar's minimum width still fits `columnCap` of these.
    static let minimumTileWidth: CGFloat = 32
    /// The previous grid was four across. Wider sidebars grow the tiles; they do not add a column.
    static let columnCap = 4

    /// How many tiles fit in `width`, never more than `columnCap`.
    static func maxPerRow(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let slot = minimumTileWidth + spacing
        let fitted = Int((width + spacing) / slot)
        return min(columnCap, max(1, fitted))
    }

    /// `ceil(itemCount / maxPerRow)` rows. Earlier rows take the remainder, so lengths differ by at most one.
    /// 6 with a max of 4 is 3+3, 5 is 3+2, 7 is 4+3, 9 is 3+3+3.
    static func rowCounts(itemCount: Int, maxPerRow: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        let limit = max(1, maxPerRow)
        let rows = (itemCount + limit - 1) / limit
        let base = itemCount / rows
        let extra = itemCount % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }
}

/// Favorites for one space. Each row's tiles share that row's width so the edges line up.
struct FavoritesGrid: View {
    var spaceID: UUID
    var onRename: (SidebarItem) -> Void
    var onNewFolder: () -> Void

    @Environment(BrowserModel.self) private var model
    @State private var emptyToken = UUID()
    /// Matches a default sidebar before the first measurement, which is already four columns.
    @State private var width: CGFloat = SidebarMetrics.defaultWidth - 12

    var body: some View {
        let items = model.library.siblings(of: nil, section: .favorites, in: spaceID).items
        if items.isEmpty {
            Color.clear
                .frame(height: 12)
                .sidebarDropTarget(.tail(spaceID: spaceID, section: .favorites, token: emptyToken))
        } else {
            balancedGrid(items)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .animation(SidebarMotion.row, value: items.map(\.id))
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { width = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, newWidth in
                                width = newWidth
                            }
                    }
                }
        }
    }

    private func balancedGrid(_ items: [SidebarItem]) -> some View {
        let counts = FavoriteGridLayout.rowCounts(
            itemCount: items.count,
            maxPerRow: FavoriteGridLayout.maxPerRow(for: width)
        )
        return VStack(spacing: FavoriteGridLayout.spacing) {
            ForEach(Array(counts.enumerated()), id: \.offset) { row, _ in
                HStack(spacing: FavoriteGridLayout.spacing) {
                    ForEach(rowItems(items, row: row, counts: counts)) { item in
                        tile(item)
                    }
                }
            }
        }
    }

    private func rowItems(_ items: [SidebarItem], row: Int, counts: [Int]) -> [SidebarItem] {
        let start = counts.prefix(row).reduce(0, +)
        let end = min(items.count, start + counts[row])
        guard start < end else { return [] }
        return Array(items[start..<end])
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
                .frame(height: FavoriteGridLayout.tileHeight)
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
        .frame(maxWidth: .infinity)
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
