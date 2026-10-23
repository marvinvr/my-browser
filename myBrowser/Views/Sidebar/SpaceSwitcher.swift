import AppKit
import SwiftUI

/// Space icons along the bottom of the sidebar, plus a button that creates one.
/// Every icon shares one hit target. Selection is a tinted rounded chip, not a filled circle.
struct SpaceSwitcher: View {
    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorMode: SpaceEditorMode?

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
            spaceGlyph(space)
                .frame(width: SidebarMetrics.spaceTarget, height: SidebarMetrics.spaceTarget)
                .background {
                    FlatFill(color: chipColor(selected: selected, color: space.color), cornerRadius: SidebarMetrics.spaceCorner)
                }
                .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.spaceCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(SidebarMotion.row, value: selected)
        .sidebarDropTarget(.space(space.id))
        .contextMenu {
            Button("Rename…") {
                interaction.editingID = nil
                model.selectSpace(space.id)
                interaction.editingSpaceID = space.id
            }
            Button("Edit…") { editorMode = .edit(space) }
            Button("Delete", role: .destructive) { model.deleteSpace(space.id) }
                .disabled(onlySpace)
        }
    }

    @ViewBuilder
    private func spaceGlyph(_ space: Space) -> some View {
        if let emoji = space.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: SidebarMetrics.spaceEmoji))
        } else {
            Image(systemName: space.symbol)
                .font(.system(size: SidebarMetrics.spaceSymbol, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(space.color.color)
        }
    }

    private var newSpaceButton: some View {
        Button {
            editorMode = .create
        } label: {
            Image(systemName: "plus")
                .font(.system(size: SidebarMetrics.spacePlus, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: SidebarMetrics.spaceTarget, height: SidebarMetrics.spaceTarget)
                .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.spaceCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("New Space")
        .accessibilityLabel("New Space")
    }

    /// Space tint at ~16–18%, pinned as an sRGB color so vibrancy cannot turn it solid.
    private func chipColor(selected: Bool, color: SpaceColor) -> NSColor {
        guard selected else { return .clear }
        let alpha: CGFloat = colorScheme == .dark ? 0.18 : 0.16
        let base = nsColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var ignored: CGFloat = 0
        let rgb = base.usingColorSpace(.sRGB) ?? base
        rgb.getRed(&red, green: &green, blue: &blue, alpha: &ignored)
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func nsColor(_ color: SpaceColor) -> NSColor {
        switch color {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .gray: .systemGray
        }
    }
}
