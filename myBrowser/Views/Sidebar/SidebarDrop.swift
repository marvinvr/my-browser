import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Drag this row and accept drops on it. The source fades while it is the dragged item.
    func sidebarDragRow(item: SidebarItem, depth: Int, axis: SidebarDropAxis = .vertical) -> some View {
        modifier(SidebarDragSourceModifier(itemID: item.id))
            .modifier(SidebarDropModifier(context: .row(item, depth: depth, axis: axis)))
    }

    func sidebarDropTarget(_ context: SidebarDropContext) -> some View {
        modifier(SidebarDropModifier(context: context))
    }
}

private struct SidebarDragSourceModifier: ViewModifier {
    var itemID: UUID

    @Environment(SidebarInteraction.self) private var interaction

    func body(content: Content) -> some View {
        let itemID = itemID
        content
            .opacity(interaction.draggingID == itemID ? 0.38 : 1)
            .animation(SidebarMotion.row, value: interaction.draggingID == itemID)
            .draggable(SidebarItemTransfer.self) {
                SidebarDragBridge.arm(itemID)
                return SidebarItemTransfer(id: itemID)
            }
            .dragConfiguration(DragConfiguration(allowMove: true))
            .onDragSessionUpdated { session in
                let phase = session.phase
                let ids = session.draggedItemIDs(for: UUID.self)
                MainActor.assumeIsolated {
                    SidebarInteractionHook.shared?.noteDrag(phase: phase, ids: ids)
                }
            }
    }
}

/// One drop target for sidebar rows, empty areas, and space icons.
/// `DropDelegate` is main-actor isolated and reports the pointer, which `dropDestination` does not
/// while a drag is still moving.
private struct SidebarDropModifier: ViewModifier {
    var context: SidebarDropContext

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @State private var box: SidebarDropBox
    @State private var delegate: SidebarRowDropDelegate

    init(context: SidebarDropContext) {
        self.context = context
        let box = SidebarDropBox(context: context)
        _box = State(initialValue: box)
        _delegate = State(initialValue: SidebarRowDropDelegate(box: box))
    }

    func body(content: Content) -> some View {
        configured(content)
    }

    private func configured(_ content: Content) -> some View {
        box.context = context
        delegate.box = box
        delegate.interaction = interaction
        interaction.model = model
        SidebarInteractionHook.shared = interaction
        return content
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { box.size = geo.size }
                        .onChange(of: geo.size) { _, newSize in box.size = newSize }
                }
            }
            .overlay { SidebarDropChrome(context: context) }
            .onDrop(of: SidebarRowDropDelegate.types, delegate: delegate)
    }
}

@MainActor
final class SidebarRowDropDelegate: DropDelegate {
    var box: SidebarDropBox
    weak var interaction: SidebarInteraction?

    static let types: [UTType] = [.myBrowserSidebarItem, .url, .plainText, .text, .data]

    init(box: SidebarDropBox) {
        self.box = box
    }

    private var draggedID: UUID? {
        interaction?.draggingID ?? SidebarDragBridge.armedID
    }

    func validateDrop(info: DropInfo) -> Bool {
        if draggedID != nil { return true }
        return info.hasItemsConforming(to: [.url, .plainText, .text])
    }

    func dropEntered(info: DropInfo) {
        update(info, active: true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info, active: true)
        let operation = interaction?.operation(
            context: box.context,
            location: info.location,
            size: box.size,
            draggedID: draggedID
        ) ?? .copy
        return DropProposal(operation: operation)
    }

    func dropExited(info: DropInfo) {
        update(info, active: false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let context = box.context
        let size = box.size
        let location = info.location
        if let id = draggedID {
            interaction?.performItem(id, context: context, location: location, size: size)
            return true
        }
        if let provider = info.itemProviders(for: [.url]).first {
            _ = provider.loadTransferable(type: URL.self) { result in
                let url = try? result.get()
                Task { @MainActor in
                    guard let url else { return }
                    SidebarInteractionHook.shared?.performExternal(url, context: context, location: location, size: size)
                }
            }
            return true
        }
        if let provider = info.itemProviders(for: [.plainText, .text]).first {
            _ = provider.loadTransferable(type: String.self) { result in
                let text = try? result.get()
                Task { @MainActor in
                    guard let text else { return }
                    if let id = SidebarItemTransfer.id(from: text) {
                        SidebarInteractionHook.shared?.performItem(id, context: context, location: location, size: size)
                    } else {
                        SidebarInteractionHook.shared?.performText(text, context: context, location: location, size: size)
                    }
                }
            }
            return true
        }
        return false
    }

    private func update(_ info: DropInfo, active: Bool) {
        interaction?.noteHover(
            context: box.context,
            phase: active ? .active : .exiting,
            location: info.location,
            size: box.size,
            draggedID: draggedID
        )
    }
}

/// The drop closures cannot capture the main-actor interaction, so the sidebar installs it here.
enum SidebarInteractionHook {
    nonisolated(unsafe) static weak var shared: SidebarInteraction?
}

private struct SidebarDropChrome: View {
    var context: SidebarDropContext

    @Environment(SidebarInteraction.self) private var interaction

    var body: some View {
        ZStack {
            if showsFolderHighlight {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .allowsHitTesting(false)
            }
            if showsSpaceHighlight {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            if let insertion = insertion, insertion.indicatorToken == context.token {
                SidebarInsertionLine(depth: insertion.depth, edge: insertion.lineEdge)
            }
        }
        .animation(SidebarMotion.row, value: interaction.proposal)
    }

    private var insertion: SidebarInsertion? {
        guard case .insert(let insertion) = interaction.proposal else { return nil }
        return insertion
    }

    private var showsFolderHighlight: Bool {
        guard case .intoFolder(let id) = interaction.proposal else { return false }
        return context.row?.id == id
    }

    private var showsSpaceHighlight: Bool {
        guard context.kind == .space else { return false }
        if case .ontoSpace(let id) = interaction.proposal { return id == context.spaceID }
        return interaction.hoverToken == context.token && interaction.proposal != nil
    }
}

struct SidebarInsertionLine: View {
    var depth: Int
    var edge: SidebarLineEdge

    var body: some View {
        let leading = SidebarDropGeometry.rowLeading + CGFloat(depth) * SidebarDropGeometry.indent
        Group {
            switch edge {
            case .top, .bottom:
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.leading, leading)
                    .padding(.trailing, 8)
                    .frame(maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
            case .leading, .trailing:
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Inline title editor for a folder or a pin. Escape discards; Return and focus loss commit.
struct SidebarInlineField: View {
    var itemID: UUID
    var title: String

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction
    @State private var draft = ""
    @State private var armed = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onAppear {
                draft = title
                focused = true
                armed = true
            }
            .onSubmit(commit)
            .onExitCommand {
                interaction.editingID = nil
            }
            .onChange(of: focused) { _, isFocused in
                if armed, !isFocused { commit() }
            }
    }

    private func commit() {
        guard interaction.editingID == itemID else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != title {
            model.rename(itemID, to: trimmed)
        }
        interaction.editingID = nil
    }
}

/// Delete / forward-delete on the focused folder. Text fields and the page keep the key.
struct SidebarDeleteMonitor: NSViewRepresentable {
    var onDelete: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.windowNumber = view.window?.windowNumber ?? 0
        context.coordinator.onDelete = onDelete
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.windowNumber = nsView.window?.windowNumber ?? 0
        context.coordinator.onDelete = onDelete
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    /// The monitor callback is `@Sendable` and returns synchronously. The view's window number and
    /// the delete action are written on the main actor and read from that callback.
    nonisolated final class Coordinator: @unchecked Sendable {
        nonisolated(unsafe) var windowNumber: Int = 0
        nonisolated(unsafe) var onDelete: () -> Bool = { false }
        nonisolated(unsafe) var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.consume(event) ? nil : event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func consume(_ event: NSEvent) -> Bool {
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            let eventWindow = event.windowNumber
            let mine = windowNumber
            return MainActor.assumeIsolated {
                let flags = NSEvent.ModifierFlags(rawValue: rawFlags).intersection([.command, .control, .option, .shift])
                let isDelete = keyCode == 51 || keyCode == 117
                guard isDelete, flags.isEmpty, mine != 0, eventWindow == mine else { return false }
                return self.onDelete()
            }
        }
    }
}
