import SwiftUI

/// A site row shared by pinned items and today's tabs.
struct SidebarRow: View {
    var item: SidebarItem
    var depth: Int = 0
    var showsLoadedState: Bool = false
    var namespace: Namespace.ID
    var onRename: () -> Void
    var onNewFolderInside: () -> Void = {}

    @Environment(BrowserModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let tab = model.tabs[item.id]
        let title = SidebarTitle.text(for: item, tab: tab)
        let isSelected = model.selectedItemID == item.id
        let isLoaded = tab?.isLoaded == true

        HStack(spacing: 0) {
            Button {
                model.select(item.id)
            } label: {
                HStack(spacing: 8) {
                    FaviconView(image: tab?.favicon, url: item.url ?? tab?.url, title: title, size: 16)
                        .opacity(isLoaded || isSelected ? 1 : 0.78)
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6 + CGFloat(depth) * 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                Button {
                    model.close(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
                .transition(.opacity)
                .accessibilityLabel("Close \(title)")
            }
        }
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            SidebarSelectionBackground(
                isSelected: isSelected,
                isHovering: hovering,
                isLoaded: showsLoadedState && isLoaded,
                namespace: namespace
            )
        }
        .onContinuousHover { phase in
            if case .active = phase {
                hovering = true
            } else {
                hovering = false
            }
        }
        .animation(SidebarMotion.selection, value: hovering)
        .modifier(SidebarItemMenu(item: item, onRename: onRename, onNewFolderInside: onNewFolderInside))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
