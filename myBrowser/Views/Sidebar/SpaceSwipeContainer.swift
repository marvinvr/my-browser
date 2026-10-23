import AppKit
import SwiftUI

/// Springs used while a space swipe is on the finger, and after it lifts.
enum SpaceSwipeMotion {
    /// Perceptual length of the release. Critically damped, so it arrives without a bounce or a long tail.
    static let duration: TimeInterval = 0.22
    static let spring = Spring(duration: duration, bounce: 0)
    /// Tight and non-bouncing so each scroll sample stays on the finger.
    static let tracking = Animation.interactiveSpring(response: 0.08, dampingFraction: 1, blendDuration: 0.04)
    /// Click and shortcut. A swipe release passes the finger speed to `animation(velocity:delta:)`.
    static var settle: Animation { animation(velocity: 0, delta: 1) }

    /// `velocity` is points per second along the column. The interpolating spring drives a unit
    /// interval, so the speed handed to it is the fraction of `delta` covered per second.
    static func animation(velocity: CGFloat, delta: CGFloat) -> Animation {
        let relative = delta == 0 ? 0 : Double(velocity / delta)
        return .interpolatingSpring(spring, initialVelocity: relative)
    }

    /// Keeps the part of `velocity` that still has to cover `to - from`, and caps it so a flick
    /// cannot run past the rest point. Opposite speeds are dropped; the spring pulls those back.
    static func carried(from: CGFloat, to: CGFloat, velocity: CGFloat) -> CGFloat {
        let delta = to - from
        guard delta != 0 else { return 0 }
        let toward = delta > 0 ? max(velocity, 0) : min(velocity, 0)
        let cap = delta / 0.08
        return delta > 0 ? min(toward, cap) : max(toward, cap)
    }
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
    @State private var columnWidth: CGFloat = SidebarMetrics.defaultWidth
    @State private var swipeGate = HapticGate<SpaceSwipeAction>()
    /// Space the finger started on. The columns stay built around it until the spring ends.
    @State private var gestureAnchor: UUID?
    /// Selection already applied for this drag. `.none` means the anchor is still selected.
    @State private var previewAction: SpaceSwipeAction = .none
    @State private var swipeSettling = false

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
            beginTrackingIfNeeded()
            noteSpaceDetent(for: value)
            let anchor = gestureAnchor ?? displayedSpaceID ?? model.selectedSpaceID
            model.spaceContent.track?(anchor, value, columnWidth)
            commitPreview(for: value, anchor: anchor)
            settleToken += 1
            var transaction = Transaction()
            transaction.animation = SpaceSwipeMotion.tracking
            withTransaction(transaction) { offset = value }
        case .settle(let value, let action, let rawVelocity):
            noteSpaceDetent(action)
            settleToken += 1
            let token = settleToken
            let anchor = gestureAnchor ?? displayedSpaceID ?? model.selectedSpaceID
            model.spaceContent.gestureActive = true
            swipeSettling = true
            commit(action, anchor: anchor, kind: "swipe-settle")
            let carried = SpaceSwipeMotion.carried(from: offset, to: value, velocity: rawVelocity)
            model.spaceContent.settle?(value, columnWidth, carried)
            withAnimation(SpaceSwipeMotion.animation(velocity: carried, delta: value - offset)) {
                offset = value
            } completion: {
                guard token == settleToken else { return }
                SpaceSwitchTrace.mark("sidebar-settled")
                endSwipe()
            }
        }
    }

    private func beginTrackingIfNeeded() {
        guard swipeSettling || gestureAnchor == nil else { return }
        swipeSettling = false
        previewAction = .none
        gestureAnchor = displayedSpaceID ?? model.selectedSpaceID
        model.spaceContent.gestureActive = true
    }

    /// Selects the neighbour the finger has crossed the commit line toward, or returns to the anchor.
    private func commitPreview(for offset: CGFloat, anchor: UUID) {
        let spaces = model.library.orderedSpaces
        let index = spaces.firstIndex { $0.id == anchor } ?? 0
        let action = SpaceSwipeTracker.armedDetent(
            offset: offset,
            width: columnWidth,
            canGoPrevious: index > 0,
            canGoNext: index + 1 < spaces.count
        )
        commit(action, anchor: anchor, kind: "swipe-threshold")
    }

    private func commit(_ action: SpaceSwipeAction, anchor: UUID, kind: String) {
        guard action != previewAction || kind == "swipe-settle" else { return }
        let target = spaceID(for: action, anchor: anchor)
        previewAction = action
        guard model.selectedSpaceID != target else { return }
        let started = SpaceSwitchTrace.begin(kind)
        model.spaceContent.gestureActive = true
        model.selectSpace(target)
        let shown = model.spaceContent.isShowing?(target) == true
        SpaceSwitchTrace.end(started, kind, shown ? "visible" : "pending")
    }

    private func spaceID(for action: SpaceSwipeAction, anchor: UUID) -> UUID {
        let spaces = model.library.orderedSpaces
        guard let index = spaces.firstIndex(where: { $0.id == anchor }) else { return anchor }
        switch action {
        case .none:
            return anchor
        case .selectPrevious:
            return index > 0 ? spaces[index - 1].id : anchor
        case .selectNext:
            return index + 1 < spaces.count ? spaces[index + 1].id : anchor
        }
    }

    private func endSwipe() {
        model.spaceContent.gestureActive = false
        gestureAnchor = nil
        previewAction = .none
        swipeSettling = false
        model.spaceContent.endGesture?()
        snap(to: model.selectedSpaceID)
        relay.noteSettleFinished()
    }

    private func handleSpaceChange(to newID: UUID) {
        if model.spaceContent.gestureActive {
            return
        }
        if displayedSpaceID == newID {
            return
        }
        if forcedOffset != nil {
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

    /// One tick when the finger locks onto a neighbour, including a flick that never sat on the line.
    private func noteSpaceDetent(_ action: SpaceSwipeAction) {
        let token: SpaceSwipeAction? = action == .none ? nil : action
        guard swipeGate.changed(to: token) != nil else { return }
        Haptics.play(.spaceSnap)
    }

    private func noteSpaceDetent(for offset: CGFloat) {
        let current = displayedSpaceID ?? model.selectedSpaceID
        let spaces = model.library.orderedSpaces
        let index = spaces.firstIndex { $0.id == current } ?? 0
        noteSpaceDetent(SpaceSwipeTracker.armedDetent(
            offset: offset,
            width: columnWidth,
            canGoPrevious: index > 0,
            canGoNext: index + 1 < spaces.count
        ))
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

    #if DEBUG
    /// Measurement hook. Same machine as a real scroll sample, without the hit test.
    func debugHandle(_ sample: SpaceSwipeSample) -> SpaceSwipeUpdate {
        lock.lock()
        let update = tracker.handle(sample)
        lock.unlock()
        return update
    }
    #endif

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
            // The local monitor is on the main thread. Delivering here keeps the page on this event.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    coordinator.deliver(update)
                }
            } else {
                DispatchQueue.main.async {
                    coordinator.deliver(update)
                }
            }
        }
        let view = SpaceSwipeMonitorView(relay: relay)
        #if DEBUG
        SpaceSwipeDebugInject.send = { sample in
            let update = relay.debugHandle(sample)
            guard update != .passthrough else { return }
            coordinator.deliver(update)
        }
        #endif
        return view
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
            #if DEBUG
            SpaceSwipeDebugInject.send = nil
            #endif
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
