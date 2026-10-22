import SwiftUI

/// Space icons along the bottom of the sidebar, plus a button that creates one.
struct SpaceSwitcher: View {
    @Environment(BrowserModel.self) private var model
    @State private var editorMode: SpaceEditorMode?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
            GlassEffectContainer(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.library.orderedSpaces) { space in
                            spaceButton(space)
                        }
                        Button {
                            editorMode = .create
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("New Space")
                        .accessibilityLabel("New Space")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .sheet(item: $editorMode) { mode in
            SpaceEditor(mode: mode)
        }
    }

    private func spaceButton(_ space: Space) -> some View {
        let selected = space.id == model.selectedSpaceID
        let onlySpace = model.library.orderedSpaces.count < 2
        return Button {
            model.selectSpace(space.id)
        } label: {
            Image(systemName: space.symbol)
                .font(.system(size: selected ? 15 : 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(space.color.color)
                .frame(width: 30, height: 30)
                .background {
                    if selected {
                        Circle()
                            .fill(space.color.color.opacity(0.2))
                            .glassEffect(.clear.tint(space.color.color), in: .circle)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(SidebarMotion.selection, value: selected)
        .contextMenu {
            Button("Edit…") { editorMode = .edit(space) }
            Button("Delete", role: .destructive) { model.deleteSpace(space.id) }
                .disabled(onlySpace)
        }
    }
}
