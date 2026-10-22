import SwiftUI

/// Space icons along the bottom of the sidebar, plus a button that creates one.
/// Every icon shares one hit target. Selection is a tinted rounded chip, not a filled circle.
struct SpaceSwitcher: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorMode: SpaceEditorMode?

    private static let symbolSize: CGFloat = 16
    private static let target: CGFloat = 26
    private static let corner: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.library.orderedSpaces) { space in
                        spaceButton(space)
                    }
                    newSpaceButton
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.top, 6)
            .padding(.bottom, 12)
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
                .font(.system(size: Self.symbolSize, weight: .regular))
                .foregroundStyle(space.color.color)
                .frame(width: Self.target, height: Self.target)
                .background {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(chipFill(selected: selected, tint: space.color.color))
                }
                .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
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

    private var newSpaceButton: some View {
        Button {
            editorMode = .create
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.target, height: Self.target)
                .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("New Space")
        .accessibilityLabel("New Space")
    }

    private func chipFill(selected: Bool, tint: Color) -> Color {
        guard selected else { return .clear }
        return tint.opacity(colorScheme == .dark ? 0.32 : 0.18)
    }
}
