import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Side-by-side (or stacked) panes for one `DisplayedContent`.
/// One AppKit view owns the frames so a divider drag never rebuilds the web views.
struct SplitCanvas: NSViewRepresentable {
    var content: DisplayedContent

    @Environment(BrowserModel.self) private var model

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitCanvasView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
    }

    func makeNSView(context: Context) -> SplitCanvasView {
        let view = SplitCanvasView()
        view.attach(model: model, content: content)
        return view
    }

    func updateNSView(_ view: SplitCanvasView, context: Context) {
        view.attach(model: model, content: content)
    }
}

final class SplitCanvasView: NSView {
    private var model: BrowserModel?
    private var content: DisplayedContent?
    private var liveShares: [Double]?
    private var dragOrigin: [Double]?
    private var hoveredID: UUID?
    private var dropIndex: Int?
    private var containers: [UUID: SplitPaneContainer] = [:]
    private var pills: [UUID: PanePillModel] = [:]
    private var dividers: [SplitDividerView] = []
    private let highlight = SplitHighlightView()
    private let catcher = SplitDropCatcherView()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlight.isHidden = true
        addSubview(highlight)
        addSubview(catcher)
        catcher.allows = { [weak self] id, index in self?.allows(id, at: index) ?? false }
        catcher.onHover = { [weak self] id in self?.setHovered(id) }
        catcher.onFocus = { [weak self] id in self?.focus(id) }
        catcher.onHighlight = { [weak self] index in
            guard let self, self.dropIndex != index else { return }
            self.dropIndex = index
            self.needsLayout = true
        }
        catcher.onDrop = { [weak self] id, index in self?.drop(id, at: index) }
    }

    required init?(coder: NSCoder) { nil }

    func attach(model: BrowserModel, content: DisplayedContent) {
        self.model = model
        self.content = content
        syncPanes()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let content, bounds.width > 2, bounds.height > 2 else { return }
        let vertical = content.axis == .vertical
        let total = vertical ? bounds.height : bounds.width
        let cross = vertical ? bounds.width : bounds.height
        let count = content.panes.count
        let gap: CGFloat = count > 1 ? SplitMetrics.gap : 0
        let stored = SplitGeometry.shares(from: content.panes.map(\.fraction))
        let shares = (liveShares?.count == stored.count ? liveShares : nil) ?? stored
        let spans = SplitGeometry.spans(shares: shares, total: total, gap: gap, minimum: SplitMetrics.minPane)
        let frames = spans.map { SplitGeometry.rect(span: $0, vertical: vertical, cross: cross) }

        for (index, pane) in content.panes.enumerated() where frames.indices.contains(index) {
            containers[pane.id]?.frame = frames[index]
        }
        if content.isSplit {
            for (index, divider) in dividers.enumerated() {
                divider.frame = dividerRect(index, spans: spans, vertical: vertical, cross: cross) ?? .zero
            }
        }
        catcher.frame = bounds
        catcher.hoverIDs = content.panes.map(\.id)
        catcher.paneFrames = frames
        catcher.spans = spans
        catcher.vertical = vertical
        if let dropIndex, let preview = SplitGeometry.preview(for: dropIndex, spans: spans) {
            highlight.frame = SplitGeometry.rect(span: preview, vertical: vertical, cross: cross)
            highlight.isHidden = false
            highlight.needsDisplay = true
        } else {
            highlight.isHidden = true
        }
    }

    private func syncPanes() {
        guard let content, let model else { return }
        let ids = Set(content.panes.map(\.id))
        for id in containers.keys where !ids.contains(id) {
            containers[id]?.removeFromSuperview()
            containers[id] = nil
            pills[id] = nil
        }
        for (index, pane) in content.panes.enumerated() {
            let container = containers[pane.id] ?? SplitPaneContainer()
            let pill = pills[pane.id] ?? PanePillModel()
            containers[pane.id] = container
            pills[pane.id] = pill
            container.pillState = pill
            if container.superview == nil {
                addSubview(container, positioned: .below, relativeTo: highlight)
            }
            installWebView(pane, in: container)
            configure(pill, pane: pane, index: index, content: content)
            let hovered = content.isSplit && hoveredID == pane.id
            container.apply(
                split: content.isSplit,
                focused: content.isSplit && pane.id == content.focusedID,
                hovered: hovered,
                title: pane.tab.title
            )
        }
        let dividerCount = content.isSplit && content.panes.count > 1 ? content.panes.count - 1 : 0
        let vertical = content.axis == .vertical
        if dividers.count != dividerCount || dividers.first?.vertical != vertical {
            for divider in dividers { divider.removeFromSuperview() }
            dividers = (0..<dividerCount).map { index in
                let view = SplitDividerView()
                view.vertical = vertical
                view.onDrag = { [weak self] translation, ended in
                    self?.resize(divider: index, translation: translation, ended: ended)
                }
                view.onReset = { [weak self] in self?.resetFractions() }
                addSubview(view, positioned: .above, relativeTo: highlight)
                return view
            }
        }
        addSubview(catcher)
    }

    private func installWebView(_ pane: DisplayedPane, in container: SplitPaneContainer) {
        guard let model, let tab = model.tabs[pane.id] else {
            container.showWebView(nil)
            return
        }
        if content?.focusedID == pane.id || tab.isLoaded {
            tab.loadIfNeeded(using: model.profiles)
        }
        container.showWebView(tab.webView)
        tab.restoreHistoryWhenWindowed()
    }

    private func configure(_ pill: PanePillModel, pane: DisplayedPane, index: Int, content: DisplayedContent) {
        pill.vertical = content.axis == .vertical
        pill.canMovePrevious = index > 0
        pill.canMoveNext = index < content.panes.count - 1
        pill.visible = content.isSplit && hoveredID == pane.id
        let tabID = pane.id
        pill.onClose = { [weak self] in self?.model?.close(tabID) }
        pill.onSeparate = { [weak self] in self?.model?.separate(tabID: tabID) }
        pill.onPrevious = { [weak self] in self?.move(tabID, by: -1) }
        pill.onNext = { [weak self] in self?.move(tabID, by: 1) }
    }

    private func move(_ tabID: UUID, by delta: Int) {
        guard let index = content?.panes.firstIndex(where: { $0.id == tabID }) else { return }
        model?.movePane(tabID: tabID, to: index + delta)
    }

    private func dividerRect(_ index: Int, spans: [SplitSpan], vertical: Bool, cross: CGFloat) -> CGRect? {
        guard spans.indices.contains(index), spans.indices.contains(index + 1) else { return nil }
        let leading = spans[index]
        let trailing = spans[index + 1]
        let boundary = (leading.origin + leading.length + trailing.origin) / 2
        let origin = boundary - SplitMetrics.dividerHit / 2
        if vertical {
            return CGRect(x: 0, y: origin, width: cross, height: SplitMetrics.dividerHit)
        }
        return CGRect(x: origin, y: 0, width: SplitMetrics.dividerHit, height: cross)
    }

    private func resize(divider: Int, translation: CGFloat, ended: Bool) {
        guard let content, content.isSplit else { return }
        let vertical = content.axis == .vertical
        let total = vertical ? bounds.height : bounds.width
        let gap = SplitMetrics.gap * CGFloat(max(content.panes.count - 1, 0))
        let available = max(1, total - gap)
        let start = dragOrigin ?? SplitGeometry.shares(from: content.panes.map(\.fraction))
        if dragOrigin == nil { dragOrigin = start }
        let next = SplitGeometry.sharesByDragging(
            start: start,
            divider: divider,
            translation: translation,
            available: available,
            minimum: SplitMetrics.minPane
        )
        if ended {
            model?.setFractions(splitID: content.itemID, next)
            liveShares = nil
            dragOrigin = nil
        } else {
            liveShares = next
        }
        needsLayout = true
    }

    private func resetFractions() {
        guard let content, content.isSplit else { return }
        liveShares = nil
        dragOrigin = nil
        model?.setFractions(splitID: content.itemID, [])
        needsLayout = true
    }

    private func focus(_ tabID: UUID) {
        guard let content, content.isSplit, content.focusedID != tabID else { return }
        model?.focusPane(tabID: tabID)
    }

    private func setHovered(_ id: UUID?) {
        guard hoveredID != id else { return }
        hoveredID = id
        guard let content, content.isSplit else { return }
        for pane in content.panes {
            pills[pane.id]?.visible = pane.id == id
            containers[pane.id]?.apply(
                split: true,
                focused: pane.id == content.focusedID,
                hovered: pane.id == id,
                title: pane.tab.title
            )
        }
    }

    private func drop(_ tabID: UUID, at insertion: Int) {
        dropIndex = nil
        highlight.isHidden = true
        guard let content, allows(tabID, at: insertion) else { return }
        Haptics.play(.drop)
        let index = destination(for: tabID, insertion: insertion)
        if content.isSplit {
            model?.addToSplit(tabID: tabID, splitID: content.itemID, at: index)
            model?.focusPane(tabID: tabID)
        } else {
            let ids = index == 0 ? [tabID, content.itemID] : [content.itemID, tabID]
            guard model?.createSplit(tabIDs: ids) != nil else { return }
            model?.focusPane(tabID: tabID)
        }
    }

    private func allows(_ tabID: UUID, at insertion: Int) -> Bool {
        guard let content, canAccept(tabID) else { return false }
        guard let current = content.panes.firstIndex(where: { $0.id == tabID }) else { return true }
        return SplitGeometry.finalIndex(current: current, insertion: insertion) != current
    }

    private func destination(for tabID: UUID, insertion: Int) -> Int {
        let current = content?.panes.firstIndex(where: { $0.id == tabID })
        return SplitGeometry.finalIndex(current: current, insertion: insertion)
    }

    private func canAccept(_ tabID: UUID) -> Bool {
        guard let model, let content else { return false }
        guard let item = model.library.item(tabID), item.kind == .site, item.section != .favorites else { return false }
        guard let host = model.library.item(content.itemID), item.spaceID == host.spaceID else { return false }
        if let container = model.library.splitContainer(of: tabID) {
            return content.isSplit && container.id == content.itemID
        }
        if content.isSplit {
            return content.panes.count < SidebarItem.maximumSplitMembers
                || content.panes.contains { $0.id == tabID }
        }
        return tabID != content.itemID
    }
}


final class SplitHighlightView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: SplitMetrics.cornerRadius, yRadius: SplitMetrics.cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}


private struct SplitDivider: NSViewRepresentable {
    var vertical: Bool
    var onDrag: (CGFloat, Bool) -> Void
    var onReset: () -> Void

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitDividerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> SplitDividerView {
        let view = SplitDividerView()
        view.vertical = vertical
        view.onDrag = onDrag
        view.onReset = onReset
        return view
    }

    func updateNSView(_ view: SplitDividerView, context: Context) {
        view.vertical = vertical
        view.onDrag = onDrag
        view.onReset = onReset
        view.window?.invalidateCursorRects(for: view)
    }
}

final class SplitDividerView: NSView {
    var vertical = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onDrag: (CGFloat, Bool) -> Void = { _, _ in }
    var onReset: () -> Void = {}

    private var start: CGFloat = 0
    private var dragging = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            dragging = false
            onReset()
            return
        }
        dragging = true
        start = axisValue(event)
        needsDisplay = true
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onDrag(axisValue(event) - start, false)
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDrag(axisValue(event) - start, true)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = dragging ? 0.45 : (hovering ? 0.32 : 0.16)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        let line: NSRect
        if vertical {
            line = NSRect(x: bounds.minX + 8, y: bounds.midY - 0.5, width: max(0, bounds.width - 16), height: 1)
        } else {
            line = NSRect(x: bounds.midX - 0.5, y: bounds.minY + 8, width: 1, height: max(0, bounds.height - 16))
        }
        NSBezierPath(roundedRect: line, xRadius: 0.5, yRadius: 0.5).fill()
    }

    private var cursor: NSCursor { vertical ? .resizeUpDown : .resizeLeftRight }

    /// Canvas coordinates, not this view's. The divider's frame follows the drag, so a
    /// point converted into the divider itself shrinks by however far the divider already moved.
    private func axisValue(_ event: NSEvent) -> CGFloat {
        let host = superview ?? self
        let local = host.convert(event.locationInWindow, from: nil)
        return vertical ? local.y : local.x
    }
}

/// Sees sidebar drags on the edges and clicks inside a page. Clicks pass through unless a drop slot is under a sidebar drag.
private struct SplitDropCatcher: NSViewRepresentable {
    var paneIDs: [UUID]
    var paneFrames: [CGRect]
    var spans: [SplitSpan]
    var vertical: Bool
    var allows: (UUID, Int) -> Bool
    var onHover: (UUID?) -> Void
    var onFocus: (UUID) -> Void
    var onHighlight: (Int?) -> Void
    var onDrop: (UUID, Int) -> Void

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitDropCatcherView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeNSView(context: Context) -> SplitDropCatcherView {
        let view = SplitDropCatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: SplitDropCatcherView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: SplitDropCatcherView) {
        view.hoverIDs = paneIDs
        view.paneFrames = paneFrames
        view.spans = spans
        view.vertical = vertical
        view.allows = allows
        view.onHover = onHover
        view.onFocus = onFocus
        view.onHighlight = onHighlight
        view.onDrop = onDrop
    }
}

final class SplitDropCatcherView: NSView {
    var paneFrames: [CGRect] = []
    var spans: [SplitSpan] = []
    var vertical = false
    var allows: (UUID, Int) -> Bool = { _, _ in false }
    var onHover: (UUID?) -> Void = { _ in }
    var onFocus: (UUID) -> Void = { _ in }
    var onHighlight: (Int?) -> Void = { _ in }
    var onDrop: (UUID, Int) -> Void = { _, _ in }

    private let monitors = SplitEventBox()
    private let bridge = SplitEventBridge()
    private var highlighted: Int?
    private var lastHover: UUID?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.myBrowserSidebarItem.identifier),
            .string,
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let id = Self.armedID(), bounds.contains(convert(point, from: superview)) else { return nil }
        let local = convert(point, from: superview)
        guard let index = dropIndex(at: local), allows(id, index) else { return nil }
        return self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            monitors.clear()
            return
        }
        window?.acceptsMouseMovedEvents = true
        bridge.view = self
        let bridge = bridge
        monitors.install { event in
            let type = event.type
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                bridge.view?.handle(type: type, windowNumber: windowNumber, location: location)
            }
            return event
        }
    }

    deinit {
        monitors.clear()
    }

    func handle(type: NSEvent.EventType, windowNumber: Int, location: CGPoint) {
        guard window?.windowNumber == windowNumber else { return }
        let local = convert(location, from: nil)
        switch type {
        case .mouseMoved:
            let hit = paneID(at: local)
            guard hit != lastHover else { return }
            lastHover = hit
            onHover(hit)
        case .leftMouseDown:
            if let hit = paneID(at: local) {
                onFocus(hit)
            }
        default:
            break
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        publish(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let local = convert(sender.draggingLocation, from: nil)
        defer { publish(nil) }
        guard let id = draggedID(from: sender), let index = dropIndex(at: local), allows(id, index) else {
            return false
        }
        onDrop(id, index)
        return true
    }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let local = convert(sender.draggingLocation, from: nil)
        guard let id = draggedID(from: sender), let index = dropIndex(at: local), allows(id, index) else {
            publish(nil)
            return []
        }
        publish(index)
        return .move
    }

    private func publish(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        onHighlight(index)
        if index != nil {
            Haptics.play(.dropSlot)
        }
    }

    private func dropIndex(at local: CGPoint) -> Int? {
        guard bounds.contains(local) else { return nil }
        let point = vertical ? local.y : local.x
        return SplitGeometry.dropIndex(
            at: point,
            spans: spans,
            edgeFraction: SplitMetrics.edgeFraction,
            dividerReach: SplitMetrics.dividerReach
        )
    }

    var hoverIDs: [UUID] = []

    private func paneID(at local: CGPoint) -> UUID? {
        guard hoverIDs.count == paneFrames.count else { return nil }
        for (index, frame) in paneFrames.enumerated() where frame.contains(local) {
            return hoverIDs[index]
        }
        return nil
    }

    private func draggedID(from sender: NSDraggingInfo) -> UUID? {
        if let id = Self.armedID() { return id }
        let board = sender.draggingPasteboard
        let type = NSPasteboard.PasteboardType(UTType.myBrowserSidebarItem.identifier)
        if let data = board.data(forType: type) {
            if let item = try? JSONDecoder().decode(SidebarItemTransfer.self, from: data) {
                return item.id
            }
            if let text = String(data: data, encoding: .utf8), let id = SidebarItemTransfer.id(from: text) {
                return id
            }
        }
        if let text = board.string(forType: .string), let id = SidebarItemTransfer.id(from: text) {
            return id
        }
        return nil
    }

    private static func armedID() -> UUID? {
        SidebarInteractionHook.shared?.draggingID ?? SidebarDragBridge.armedID
    }
}

nonisolated private final class SplitEventBridge: @unchecked Sendable {
    nonisolated(unsafe) weak var view: SplitDropCatcherView?
}

nonisolated private final class SplitEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: Any?

    func install(_ handler: @escaping @Sendable (NSEvent) -> NSEvent?) {
        lock.lock()
        defer { lock.unlock() }
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown], handler: handler)
    }

    func clear() {
        lock.lock()
        let installed = token
        token = nil
        lock.unlock()
        if let installed {
            NSEvent.removeMonitor(installed)
        }
    }

    deinit { clear() }
}
