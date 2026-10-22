import SwiftUI

/// Arc-style sidebar: navigation, favorites, pins, tabs, and spaces.
struct SidebarView: View {
    var traffic: TrafficLightAnchor = .fallback

    @Environment(BrowserModel.self) private var model
    @Namespace private var selectionNamespace
    @State private var prompt: SidebarPrompt?
    @State private var shownSpaceID: UUID?
    @State private var slidesForward = true

    var body: some View {
        VStack(spacing: 0) {
            SidebarToolbar(traffic: traffic)
            ZStack {
                spaceColumn(displayedSpaceID)
                    .id(displayedSpaceID)
                    .transition(spaceTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            SpaceSwitcher()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $prompt) { prompt in
            NamePrompt(
                title: prompt.title,
                confirmTitle: prompt.confirmTitle,
                initialName: prompt.initialName
            ) { name in
                apply(prompt, name: name)
            }
        }
        .onChange(of: model.selectedSpaceID, initial: true) { old, new in
            // The initial callback reports the current id as both values; don't slide on appear.
            if shownSpaceID == nil || old == new {
                shownSpaceID = new
            } else {
                slidesForward = spaceIndex(new) >= spaceIndex(old)
                withAnimation(SidebarMotion.space) {
                    shownSpaceID = new
                }
            }
        }
    }

    private var displayedSpaceID: UUID {
        shownSpaceID ?? model.selectedSpaceID
    }

    private var spaceTransition: AnyTransition {
        let insertionX: CGFloat = slidesForward ? 26 : -26
        let removalX: CGFloat = slidesForward ? -16 : 16
        return .asymmetric(
            insertion: .offset(x: insertionX).combined(with: .opacity),
            removal: .offset(x: removalX).combined(with: .opacity)
        )
    }

    private func spaceColumn(_ spaceID: UUID) -> some View {
        GeometryReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: 10) {
                    scrollColumn(spaceID, minHeight: proxy.size.height)
                }
            }
        }
    }

    private func scrollColumn(_ spaceID: UUID, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FavoritesGrid(spaceID: spaceID, namespace: selectionNamespace, onRename: askRename)
            if let name = model.library.space(spaceID)?.name {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            }
            PinnedTree(
                spaceID: spaceID,
                namespace: selectionNamespace,
                onRename: askRename,
                onNewFolder: askNewFolder
            )
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            TabList(spaceID: spaceID, namespace: selectionNamespace, onRename: askRename)
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("New Folder") { askNewFolder(nil) }
                }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
    }

    private func spaceIndex(_ id: UUID) -> Int {
        model.library.orderedSpaces.firstIndex { $0.id == id } ?? 0
    }

    private func askRename(_ item: SidebarItem) {
        prompt = SidebarPrompt(kind: .rename(item.id), initialName: item.title)
    }

    private func askNewFolder(_ parentID: UUID?) {
        prompt = SidebarPrompt(kind: .newFolder(parentID: parentID), initialName: "")
    }

    private func apply(_ prompt: SidebarPrompt, name: String) {
        switch prompt.kind {
        case .rename(let id):
            model.rename(id, to: name)
        case .newFolder(let parentID):
            model.createFolder(named: name, parentID: parentID)
        }
    }
}

#if DEBUG
#Preview("Sidebar") {
    PreviewHost {
        SidebarView()
    }
    .frame(width: 240, height: 780)
}

#Preview("Sidebar Dark") {
    PreviewHost {
        SidebarView()
    }
    .frame(width: 240, height: 780)
    .preferredColorScheme(.dark)
}
#endif
