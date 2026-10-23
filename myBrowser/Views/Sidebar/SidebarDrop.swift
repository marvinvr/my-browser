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
        interaction?.beginHoverSession()
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
            interaction?.settleDrop()
            return true
        }
        let providers = info.itemProviders(for: [.url, .plainText, .text])
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) ?? providers.first else {
            return false
        }
        loadExternal(provider, context: context, location: location, size: size)
        interaction?.settleDrop()
        return true
    }

    /// WebKit's link drag is an `NSURL` (`public.url`). `loadTransferable(URL.self)` often
    /// fails on that payload and used to swallow the drop, so there was no plain-text fallback.
    /// The two loads start together. Their callbacks are `@Sendable` and cannot capture the provider.
    private func loadExternal(
        _ provider: NSItemProvider,
        context: SidebarDropContext,
        location: CGPoint,
        size: CGSize
    ) {
        let gate = ExternalDropGate()
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            let url = object as? URL
            guard let pair = gate.receive(url: url, text: nil, part: .url) else { return }
            Task { @MainActor in
                Self.applyExternal(pair, context: context, location: location, size: size)
            }
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            let text = object as? String
            guard let pair = gate.receive(url: nil, text: text, part: .text) else { return }
            Task { @MainActor in
                Self.applyExternal(pair, context: context, location: location, size: size)
            }
        }
    }

    private static func applyExternal(
        _ pair: (url: URL?, text: String?),
        context: SidebarDropContext,
        location: CGPoint,
        size: CGSize
    ) {
        if let resolved = SidebarDropGeometry.externalWebURL(transferable: nil, object: pair.url, text: pair.text) {
            SidebarInteractionHook.shared?.performExternal(resolved, context: context, location: location, size: size)
        } else if let text = pair.text, let sidebarID = SidebarItemTransfer.id(from: text) {
            SidebarInteractionHook.shared?.performItem(sidebarID, context: context, location: location, size: size)
        }
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

/// Joins the URL and plain-text halves of one external drop. Touched only from the provider callbacks.
private nonisolated final class ExternalDropGate: @unchecked Sendable {
    enum Part { case url, text }

    private let lock = NSLock()
    private var url: URL?
    private var text: String?
    private var urlDone = false
    private var textDone = false
    private var delivered = false

    func receive(url: URL?, text: String?, part: Part) -> (url: URL?, text: String?)? {
        lock.lock()
        defer { lock.unlock() }
        switch part {
        case .url:
            self.url = url
            urlDone = true
        case .text:
            self.text = text
            textDone = true
        }
        guard urlDone, textDone, !delivered else { return nil }
        delivered = true
        return (self.url, self.text)
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

/// Inline title editor. Return saves, Escape discards, and leaving the field saves.
/// Focus is retried: a context menu hands first responder back to the row after its action.
struct SidebarInlineField: View {
    var title: String
    var itemID: UUID? = nil
    var spaceID: UUID? = nil
    var font: NSFont = .systemFont(ofSize: 13)

    @Environment(BrowserModel.self) private var model
    @Environment(SidebarInteraction.self) private var interaction

    var body: some View {
        InlineRenameFieldRepresentable(title: title, font: font, onCommit: commit, onCancel: cancel)
            .accessibilityIdentifier("sidebar-rename")
    }

    private func commit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let itemID {
            if !trimmed.isEmpty, trimmed != title {
                model.rename(itemID, to: trimmed)
            }
            if interaction.editingID == itemID { interaction.editingID = nil }
        } else if let spaceID {
            if !trimmed.isEmpty, trimmed != title {
                model.renameSpace(spaceID, to: trimmed)
            }
            if interaction.editingSpaceID == spaceID { interaction.editingSpaceID = nil }
        }
    }

    private func cancel() {
        if let itemID, interaction.editingID == itemID { interaction.editingID = nil }
        if let spaceID, interaction.editingSpaceID == spaceID { interaction.editingSpaceID = nil }
    }
}

private struct InlineRenameFieldRepresentable: NSViewRepresentable {
    var title: String
    var font: NSFont
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(title: title, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> InlineRenameTextField {
        let field = InlineRenameTextField(string: title)
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.sendsActionOnEndEditing = false
        if let cell = field.cell as? NSTextFieldCell {
            cell.isScrollable = true
            cell.wraps = false
            cell.usesSingleLineMode = true
        }
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("sidebar-rename")
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: InlineRenameTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        if field.font != font { field.font = font }
        guard !context.coordinator.started else { return }
        context.coordinator.started = true
        context.coordinator.poke(attempt: 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InlineRenameTextField, context: Context) -> CGSize? {
        // One line. A flexible stack proposes the leftover column height; taking that
        // stretches the space-name field over the whole sidebar.
        let line = max(ceil(font.boundingRectForFont.height), font.pointSize + 2)
        let cap = line + 24
        let height: CGFloat
        if let proposed = proposal.height, proposed.isFinite, proposed > 0, proposed <= cap {
            height = proposed
        } else {
            height = line
        }
        return CGSize(width: proposal.width ?? 120, height: height)
    }

    static func dismantleNSView(_ nsView: InlineRenameTextField, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        let initial: String
        weak var field: NSTextField?
        var started = false
        private var finished = false
        private var didFocus = false
        private var monitor: Any?

        init(title: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            initial = title
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func poke(attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(attempt == 0 ? 0 : 40)) { [weak self] in
                guard let self, !self.finished, attempt < 20 else { return }
                guard let field = self.field, let window = field.window else {
                    self.poke(attempt: attempt + 1)
                    return
                }
                self.watchClicks()
                // Typing means the field is already live. Stop fighting the caret.
                if field.stringValue != self.initial { return }
                let editor = field.currentEditor()
                let focused = editor != nil && window.firstResponder === editor
                if !focused {
                    self.didFocus = false
                    if !window.isKeyWindow {
                        window.makeKeyAndOrderFront(nil)
                    }
                    // `selectText` installs the field editor and selects the title.
                    // A context menu returns first responder to the row after this runs, so keep retrying.
                    window.makeFirstResponder(field)
                    if field.currentEditor() == nil {
                        field.selectText(nil)
                    }
                    self.paint(field.currentEditor() as? NSTextView)
                    if field.currentEditor() != nil { self.didFocus = true }
                } else if !self.didFocus {
                    self.paint(editor as? NSTextView)
                    self.didFocus = true
                }
                if attempt < 19 { self.poke(attempt: attempt + 1) }
            }
        }

        /// A click that does not move first responder still ends the edit. Inside the field it does not.
        private func watchClicks() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, !self.finished, let field = self.field else { return event }
                let inside: Bool
                if event.window === field.window {
                    let point = field.convert(event.locationInWindow, from: nil)
                    inside = field.bounds.contains(point)
                } else {
                    inside = false
                }
                if !inside { self.finish(save: true) }
                return event
            }
        }

        private func paint(_ editor: NSTextView?) {
            editor?.textColor = .labelColor
            editor?.insertionPointColor = .labelColor
            editor?.selectAll(nil)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                finish(save: false)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                finish(save: true)
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard didFocus else { return }
            finish(save: true)
        }

        func stopWatching() {
            guard let monitor else { return }
            self.monitor = nil
            NSEvent.removeMonitor(monitor)
        }

        private func finish(save: Bool) {
            guard !finished else { return }
            finished = true
            let value = field?.stringValue ?? ""
            let commit = onCommit
            let cancel = onCancel
            let field = field
            stopWatching()
            DispatchQueue.main.async {
                field?.window?.makeFirstResponder(nil)
                if save { commit(value) } else { cancel() }
            }
        }
    }
}

/// Opaque field. The sidebar material would otherwise wash the insertion point out.
private final class InlineRenameTextField: NSTextField {
    override var allowsVibrancy: Bool { false }
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
