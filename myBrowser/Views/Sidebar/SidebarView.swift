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
                if interaction.editingSpaceID == spaceID {
                    SidebarInlineField(
                        title: name,
                        spaceID: spaceID,
                        font: .systemFont(ofSize: SidebarMetrics.sectionHeader, weight: .semibold)
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, SidebarMetrics.sectionHeaderTop)
                    .padding(.bottom, SidebarMetrics.sectionHeaderBottom)
                } else {
                    Text(name)
                        .font(.system(size: SidebarMetrics.sectionHeader, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.top, SidebarMetrics.sectionHeaderTop)
                        .padding(.bottom, SidebarMetrics.sectionHeaderBottom)
                }
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
        .padding(.leading, SidebarMetrics.leadingInset)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background { SidebarClickMarker() }
    }

    private func askRename(_ item: SidebarItem) {
        interaction.editingSpaceID = nil
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

/// Row buttons are SwiftUI, so the view that is actually hit — not the hosting view —
/// decides whether the click that activates the window is delivered. Mark the sidebar
/// scroll view and answer yes for views under it. Classes that implement the method
/// themselves are patched too; anything outside the scroll view keeps its old answer.
private enum SidebarActivatingClick {
    private typealias AcceptsIMP = @convention(c) (AnyObject, Selector, NSEvent?) -> Bool

    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var rootKey: UInt8 = 0
    nonisolated(unsafe) private static var patched = Set<ObjectIdentifier>()
    /// Row classes are shared, so a few walks at startup cover every later row.
    nonisolated(unsafe) private static var walks = 0
    private static let selector = #selector(NSView.acceptsFirstMouse(for:))

    static func install() {
        guard !installed else { return }
        installed = true
        patch(NSView.self)
    }

    static func mark(_ view: NSView) {
        objc_setAssociatedObject(view, &rootKey, true as NSNumber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func contains(_ view: NSView) -> Bool {
        var node: NSView? = view
        var depth = 0
        while let current = node, depth < 40 {
            if objc_getAssociatedObject(current, &rootKey) != nil { return true }
            node = current.superview
            depth += 1
        }
        return false
    }

    /// New row classes show up as the sidebar builds. Patching a class once covers later rows.
    static func patchTreeIfNeeded(_ root: NSView) {
        guard walks < 4, !root.subviews.isEmpty else { return }
        walks += 1
        patchTree(root)
    }

    private static func patchTree(_ root: NSView) {
        patchIfImplemented(type(of: root))
        for subview in root.subviews {
            patchTree(subview)
        }
    }

    private static func patch(_ cls: AnyClass) {
        let id = ObjectIdentifier(cls)
        guard patched.insert(id).inserted, let method = class_getInstanceMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: AcceptsIMP.self)
        let sel = selector
        let block: @convention(block) (AnyObject, NSEvent?) -> Bool = { object, event in
            if let view = object as? NSView, contains(view) { return true }
            return original(object, sel, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// `class_getInstanceMethod` walks superclasses. Only replace a method this class declares,
    /// or the superclass implementation (and every other view) would change with it.
    private static func patchIfImplemented(_ cls: AnyClass) {
        if patched.contains(ObjectIdentifier(cls)) { return }
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return }
        defer { free(list) }
        for index in 0..<Int(count) where method_getName(list[index]) == selector {
            patch(cls)
            return
        }
    }
}

/// Sits in the scroll content so its ancestor scroll view can be marked. It never takes a hit.
private struct SidebarClickMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarClickMarkerView {
        SidebarActivatingClick.install()
        return SidebarClickMarkerView()
    }

    func updateNSView(_ view: SidebarClickMarkerView, context: Context) {
        view.tagScrollView()
    }
}

private final class SidebarClickMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tagScrollView()
    }

    func tagScrollView() {
        var node: NSView? = superview
        var depth = 0
        while let view = node, depth < 40 {
            if view is NSScrollView {
                SidebarActivatingClick.mark(view)
                SidebarActivatingClick.patchTreeIfNeeded(view)
                return
            }
            node = view.superview
            depth += 1
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
