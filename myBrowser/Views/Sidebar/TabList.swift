import SwiftUI

/// "New Tab" plus the current space's unpinned tabs.
struct TabList: View {
    var spaceID: UUID
    var onRename: (SidebarItem) -> Void
    var onNewFolder: () -> Void

    @Environment(BrowserModel.self) private var model
    @State private var hoveringNewTab = false
    @State private var newTabToken = UUID()

    var body: some View {
        let items = model.library.siblings(of: nil, section: .tabs, in: spaceID).items
        VStack(alignment: .leading, spacing: 1) {
            Button {
                model.showCommandBar(.newTab)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16, height: 16)
                    Text("New Tab")
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(height: SidebarMetrics.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hoveringNewTab ? 0.06 : 0))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .onContinuousHover { phase in
                hoveringNewTab = if case .active = phase { true } else { false }
            }
            .animation(SidebarMotion.row, value: hoveringNewTab)
            .sidebarDropTarget(.head(spaceID: spaceID, section: .tabs, token: newTabToken))

            ForEach(items) { item in
                SidebarRow(
                    item: item,
                    onRename: { onRename(item) },
                    onNewFolderInside: onNewFolder
                )
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(SidebarMotion.row, value: items.map(\.id))
    }
}
