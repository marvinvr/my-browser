import AppKit
import SwiftUI
import WebKit

/// Arc-style sidebar: favorites, pins, tabs, and spaces.
/// Top mode keeps only the traffic-light row here. Sidebar mode hosts the address bar as well.
struct SidebarView: View {
    var traffic: TrafficLightAnchor = .fallback

    @Environment(BrowserModel.self) private var model
    @AppStorage(AddressBarPosition.defaultsKey) private var addressBarPosition: AddressBarPosition = .top
    @State private var prompt: SidebarPrompt?
    @State private var interaction = SidebarInteraction()

    var body: some View {
        VStack(spacing: 0) {
            topChrome
            SpaceSwipeContainer { spaceID in
                spaceColumn(spaceID)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            SpaceSwitcher()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(SidebarMotion.sidebar, value: addressBarPosition)
        .environment(interaction)
        .background {
            SidebarDeleteMonitor(onDelete: deleteFocusedFolder)
        }
        .sheet(item: $prompt) { prompt in
            NamePrompt(
                title: prompt.title,
                confirmTitle: prompt.confirmTitle,
                initialName: prompt.initialName
            ) { name in
                apply(prompt, name: name)
            }
        }
    }

    @ViewBuilder
    private var topChrome: some View {
        switch addressBarPosition {
        case .top:
            SidebarHeader(traffic: traffic)
        case .sidebar:
            ContentToolbar(traffic: traffic, sidebarVisible: true, style: .sidebar)
        }
    }

    private func spaceColumn(_ spaceID: UUID) -> some View {
        GeometryReader { proxy in
            ScrollView {
                scrollColumn(spaceID, minHeight: proxy.size.height)
            }
        }
    }

    private func scrollColumn(_ spaceID: UUID, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FavoritesGrid(spaceID: spaceID, onRename: askRename, onNewFolder: { askNewFolder(nil) })
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
                onRename: askRename,
                onNewFolder: askNewFolder
            )
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            TabList(spaceID: spaceID, onRename: askRename, onNewFolder: { askNewFolder(nil) })
            TabsTail(spaceID: spaceID, onNewFolder: { askNewFolder(nil) })
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
    }

    private func askRename(_ item: SidebarItem) {
        guard item.isFolder || item.section != .tabs else { return }
        interaction.editingID = item.id
    }

    /// Delete removes an empty folder immediately. A folder that still has something in it asks first.
    private func deleteFocusedFolder() -> Bool {
        guard model.commandBarMode == nil else { return false }
        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is NSTextView || responder is WKWebView { return false }
        }
        guard let id = model.sidebarFocusID, let item = model.library.item(id), item.isFolder else { return false }
        let hasContents = model.library.descendantIDs(of: id, spaceID: item.spaceID).contains { model.library.item($0) != nil }
        if hasContents {
            let name = item.title.isEmpty ? "Folder" : item.title
            let alert = NSAlert()
            alert.messageText = "Delete \"\(name)\"?"
            alert.informativeText = "This folder and everything inside it will be deleted."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return true }
        }
        model.delete(id)
        return true
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

private struct TabsTail: View {
    var spaceID: UUID
    var onNewFolder: () -> Void
    @State private var token = UUID()

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .sidebarDropTarget(.tail(spaceID: spaceID, section: .tabs, token: token))
            .contextMenu {
                Button("New Folder", action: onNewFolder)
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
