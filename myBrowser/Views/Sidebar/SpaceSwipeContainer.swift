import AppKit
import SwiftUI

/// Springs used while a space swipe is on the finger, and after it lifts.
enum SpaceSwipeMotion {
    /// Tight and non-bouncing so each scroll sample stays on the finger.
    static let tracking = Animation.interactiveSpring(response: 0.08, dampingFraction: 1, blendDuration: 0.04)
    static let settle = Animation.spring(response: 0.36, dampingFraction: 0.86)
}

/// DEBUG hook so a snapshot can show the sidebar mid-swipe. `-80` reveals the next space.
enum SpaceSwipeDebug {
    static var forcedOffset: CGFloat? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_SWIPE_OFFSET"],
              let value = Double(raw) else { return nil }
        return CGFloat(value)
        #else
        return nil
        #endif
    }
}

/// Previous, current, and next space columns, dragged by a horizontal trackpad swipe.
struct SpaceSwipeContainer<Content: View>: View {
    @Environment(BrowserModel.self) private var model
    private var content: (UUID) -> Content

    @State private var relay = SpaceSwipeRelay()
    @State private var displayedSpaceID: UUID?
    @State private var offset: CGFloat = 0
    @State private var settleToken = 0
    @State private var commitInFlight = false
    @State private var columnWidth: CGFloat = SidebarMetrics.defaultWidth

    private let forcedOffset = SpaceSwipeDebug.forcedOffset

    init(@ViewBuilder content: @escaping (UUID) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let current = displayedSpaceID ?? model.selectedSpaceID
            let pages = pages(around: current)
            let resting = pages.previous == nil ? 0 : -width
            ZStack(alignment: .topLeading) {
                carousel(pages, width: width, height: geo.size.height)
                    .offset(x: resting + displayOffset)
                    .id(current)
                    .transition(jumpTransition)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .background {
                SpaceSwipeMonitor(
                    relay: relay,
                    width: width,
                    canGoPrevious: pages.previous != nil,
                    canGoNext: pages.next != nil,
                    enabled: forcedOffset == nil,
                    onUpdate: apply
                )
                .allowsHitTesting(false)
            }
            .onAppear { columnWidth = width }
            .onChange(of: width) { _, newWidth in columnWidth = newWidth }
        }
        .onAppear {
            if displayedSpaceID == nil {
                displayedSpaceID = model.selectedSpaceID
            }
        }
        .onChange(of: model.selectedSpaceID) { _, newID in
            handleSpaceChange(to: newID)
        }
    }

    private var displayOffset: CGFloat { forcedOffset ?? offset }

    private var jumpTransition: AnyTransition {
        let forward = model.lastSpaceSwitchDirection == .next
        let insertionX: CGFloat = forward ? 26 : -26
        let removalX: CGFloat = forward ? -16 : 16
        return .asymmetric(
            insertion: .offset(x: insertionX).combined(with: .opacity),
            removal: .offset(x: removalX).combined(with: .opacity)
        )
    }

    private func pages(around current: UUID) -> SpacePages {
        let spaces = model.library.orderedSpaces
        let index = spaces.firstIndex { $0.id == current } ?? 0
        let previous = index > 0 ? spaces[index - 1].id : nil
        let next = index + 1 < spaces.count ? spaces[index + 1].id : nil
        return SpacePages(previous: previous, current: current, next: next)
    }

    private func carousel(_ pages: SpacePages, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            if let previous = pages.previous {
                page(previous, width: width, height: height)
            }
            page(pages.current, width: width, height: height)
            if let next = pages.next {
                page(next, width: width, height: height)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func page(_ id: UUID, width: CGFloat, height: CGFloat) -> some View {
        content(id)
            .frame(width: width, height: height, alignment: .top)
            .clipped()
            .id(id)
    }

    private func apply(_ update: SpaceSwipeUpdate) {
        guard forcedOffset == nil else { return }
        switch update {
        case .passthrough, .consume:
            break
        case .tracking(let value):
            settleToken += 1
            var transaction = Transaction()
            transaction.animation = SpaceSwipeMotion.tracking
            withTransaction(transaction) { offset = value }
        case .settle(let value, let action):
            settleToken += 1
            let token = settleToken
            withAnimation(SpaceSwipeMotion.settle) {
                offset = value
            } completion: {
                guard token == settleToken else { return }
                finishSwipe(action)
            }
        }
    }

    private func finishSwipe(_ action: SpaceSwipeAction) {
        switch action {
        case .none:
            break
        case .selectNext:
            commitInFlight = true
            model.selectNextSpace()
        case .selectPrevious:
            commitInFlight = true
            model.selectPreviousSpace()
        }
        snap(to: model.selectedSpaceID)
        relay.noteSettleFinished()
    }

    private func handleSpaceChange(to newID: UUID) {
        if displayedSpaceID == newID {
            commitInFlight = false
            return
        }
        if commitInFlight || forcedOffset != nil {
            commitInFlight = false
            snap(to: newID)
            return
        }
        guard let shown = displayedSpaceID else {
            displayedSpaceID = newID
            return
        }
        let spaces = model.library.orderedSpaces
        guard let oldIndex = spaces.firstIndex(where: { $0.id == shown }),
              let newIndex = spaces.firstIndex(where: { $0.id == newID }) else {
            displayedSpaceID = newID
            return
        }
        // The neighbour sits on one side of the strip, so the slide matches that side.
        // A wrap (last → first) is not a neighbour; it uses the same short slide as a jump,
        // in the direction `selectNextSpace` / `selectPreviousSpace` recorded.
        if newIndex == oldIndex + 1 {
            slideCarousel(to: -columnWidth, revealing: newID)
        } else if newIndex == oldIndex - 1 {
            slideCarousel(to: columnWidth, revealing: newID)
        } else {
            withAnimation(SidebarMotion.space) {
                displayedSpaceID = newID
                offset = 0
            }
        }
    }

    private func slideCarousel(to target: CGFloat, revealing newID: UUID) {
        settleToken += 1
        let token = settleToken
        withAnimation(SpaceSwipeMotion.settle) {
            offset = target
        } completion: {
            guard token == settleToken else { return }
            snap(to: newID)
            relay.noteSettleFinished()
        }
    }

    private func snap(to id: UUID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedSpaceID = id
            offset = 0
        }
    }
}

private struct SpacePages {
    var previous: UUID?
    var current: UUID
    var next: UUID?
}

/// Shares the gesture machine between the SwiftUI view and the AppKit monitor.
nonisolated final class SpaceSwipeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = SpaceSwipeTracker()
    private var windowNumber = 0
    private var frameInWindow: CGRect = .zero
    private var enabled = true
    private var handler: (@Sendable (SpaceSwipeUpdate) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (SpaceSwipeUpdate) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setContext(width: CGFloat, canGoPrevious: Bool, canGoNext: Bool, enabled: Bool) {
        lock.lock()
        tracker.width = width
        tracker.canGoPrevious = canGoPrevious
        tracker.canGoNext = canGoNext
        self.enabled = enabled
        lock.unlock()
    }

    func setHitBox(windowNumber: Int, frameInWindow: CGRect) {
        lock.lock()
        self.windowNumber = windowNumber
        self.frameInWindow = frameInWindow
        lock.unlock()
    }

    func noteSettleFinished() {
        lock.lock()
        tracker.noteSettleFinished()
        lock.unlock()
    }

    /// The app or the window lost focus while a drag was still down.
    func interrupt() {
        lock.lock()
        let update = tracker.interrupt()
        let handler = handler
        lock.unlock()
        guard update != .passthrough, update != .consume else { return }
        handler?(update)
    }

    /// `true` when the sidebar owns the event and the caller should swallow it.
    func ingest(
        windowNumber: Int,
        location: CGPoint,
        phaseRaw: UInt,
        momentumRaw: UInt,
        deltaX: CGFloat,
        deltaY: CGFloat,
        time: TimeInterval
    ) -> Bool {
        lock.lock()
        let armed = enabled
        let inside = armed && self.windowNumber == windowNumber && frameInWindow.contains(location)
        guard armed else {
            lock.unlock()
            return false
        }
        let update = tracker.handle(
            SpaceSwipeSample(
                phase: SpaceSwipePhase.from(phaseRaw: phaseRaw, momentumRaw: momentumRaw),
                deltaX: deltaX,
                deltaY: deltaY,
                time: time,
                inside: inside
            )
        )
        let handler = handler
        lock.unlock()
        guard update != .passthrough else { return false }
        handler?(update)
        return true
    }
}

/// Local scroll-wheel monitor hit-tested against the visible sidebar column.
/// Clicks pass through (`hitTest` is nil). The web view never sees a claimed swipe.
private struct SpaceSwipeMonitor: NSViewRepresentable {
    var relay: SpaceSwipeRelay
    var width: CGFloat
    var canGoPrevious: Bool
    var canGoNext: Bool
    var enabled: Bool
    var onUpdate: (SpaceSwipeUpdate) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SpaceSwipeMonitorView {
        let coordinator = context.coordinator
        relay.setHandler { update in
            Task { @MainActor in
                coordinator.deliver(update)
            }
        }
        return SpaceSwipeMonitorView(relay: relay)
    }

    func updateNSView(_ view: SpaceSwipeMonitorView, context: Context) {
        context.coordinator.onUpdate = onUpdate
        relay.setContext(
            width: width,
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext,
            enabled: enabled
        )
        view.publishHitBox()
    }

    /// The scroll monitor calls back off the view's actor. The closure is only written and
    /// invoked on the main actor; `nonisolated(unsafe)` keeps that hop explicit.
    nonisolated final class Coordinator: @unchecked Sendable {
        nonisolated(unsafe) var onUpdate: ((SpaceSwipeUpdate) -> Void)?

        nonisolated init() {}

        @MainActor func deliver(_ update: SpaceSwipeUpdate) {
            onUpdate?(update)
        }
    }
}

private final class SpaceSwipeMonitorView: NSView {
    private let relay: SpaceSwipeRelay
    private let monitors = MonitorBox()
    private let observers = ObserverBox()

    init(relay: SpaceSwipeRelay) {
        self.relay = relay
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            monitors.clear()
            observers.clear()
            relay.setHitBox(windowNumber: 0, frameInWindow: .zero)
            return
        }
        installLifecycleObservers()
        let relay = relay
        monitors.install { event in
            let consumed = relay.ingest(
                windowNumber: event.windowNumber,
                location: event.locationInWindow,
                phaseRaw: event.phase.rawValue,
                momentumRaw: event.momentumPhase.rawValue,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                time: event.timestamp
            )
            return consumed ? nil : event
        }
        publishHitBox()
    }

    override func layout() {
        super.layout()
        publishHitBox()
    }

    func publishHitBox() {
        guard let window else {
            relay.setHitBox(windowNumber: 0, frameInWindow: .zero)
            return
        }
        // `visibleRect` is what is not clipped away, so a hidden sidebar cannot cover the page.
        let visible = convert(visibleRect, to: nil)
        relay.setHitBox(windowNumber: window.windowNumber, frameInWindow: visible)
    }

    private func installLifecycleObservers() {
        observers.clear()
        guard let window else { return }
        let relay = relay
        let resignKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { _ in
            relay.interrupt()
        }
        let resignActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            relay.interrupt()
        }
        observers.store(resignKey)
        observers.store(resignActive)
    }

    deinit {
        monitors.clear()
        observers.clear()
    }
}

/// Notification tokens for resign-key and resign-active, removed with the monitor view.
nonisolated private final class ObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func store(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        let installed = tokens
        tokens.removeAll()
        lock.unlock()
        for token in installed {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// Holds the local-monitor token so it can be removed when the view leaves the window.
nonisolated private final class MonitorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: Any?

    func install(_ handler: @escaping @Sendable (NSEvent) -> NSEvent?) {
        lock.lock()
        defer { lock.unlock() }
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: handler)
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
