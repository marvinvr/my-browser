import AppKit
import SwiftUI

/// Extension actions for the current space's profile.
///
/// Up to four icons sit in the bar. The rest are in a puzzle-piece menu.
/// A click runs the action; popups are presented by the extension controller as an `NSPopover`.
struct ExtensionButtons: View {
    @Environment(BrowserModel.self) private var model
    @Environment(ExtensionManager.self) private var extensions

    private var profileID: UUID? { model.selectedSpace?.profileID }

    private var items: [ExtensionToolbarItem] {
        guard let profileID else { return [] }
        return extensions.toolbarItems(profileID: profileID, tab: model.selectedTab)
    }

    var body: some View {
        let _ = model.selectedTab?.url
        let _ = model.selectedTab?.isLoading
        let _ = extensions.revision
        let visible = Array(items.prefix(4))
        let overflow = Array(items.dropFirst(4))
        if !visible.isEmpty {
            HStack(spacing: 0) {
                ForEach(visible) { item in
                    button(item)
                }
                if !overflow.isEmpty {
                    overflowMenu(overflow)
                }
            }
            .fixedSize(horizontal: true, vertical: true)
            .animation(.spring(duration: 0.28, bounce: 0.15), value: visible.map(\.id) + overflow.map(\.id))
        }
    }

    private func button(_ item: ExtensionToolbarItem) -> some View {
        Button {
            guard let profileID else { return }
            extensions.performAction(extensionID: item.id, profileID: profileID, tab: model.selectedTab)
        } label: {
            ZStack(alignment: .topTrailing) {
                icon(item.image, enabled: item.isEnabled)
                if !item.badge.isEmpty {
                    Text(item.badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 2, y: 1)
                }
            }
            .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .help(item.label)
        .accessibilityLabel(item.label)
        .background(ExtensionAnchorView { view in
            extensions.registerAnchor(view, for: item.id)
        })
    }

    private func icon(_ image: NSImage?, enabled: Bool) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .opacity(enabled ? 1 : 0.38)
    }

    private func overflowMenu(_ items: [ExtensionToolbarItem]) -> some View {
        Menu {
            ForEach(items) { item in
                Button {
                    guard let profileID else { return }
                    extensions.performAction(extensionID: item.id, profileID: profileID, tab: model.selectedTab)
                } label: {
                    if let image = item.image {
                        Label {
                            Text(item.label)
                        } icon: {
                            Image(nsImage: image)
                        }
                    } else {
                        Text(item.label)
                    }
                }
                .disabled(!item.isEnabled)
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13, weight: .medium))
                .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More extensions")
        .accessibilityLabel("More extensions")
    }
}

/// Reports the AppKit view the popup anchors to.
private struct ExtensionAnchorView: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onResolve(nsView)
    }
}
