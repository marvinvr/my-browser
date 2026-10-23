import AppKit
import os
import SwiftUI

/// The content card talks to this. `BrowserModel` reveals a space here before SwiftUI redraws.
@MainActor
final class SpaceContentSurface {
    /// A sidebar swipe owns the frames. A discrete switch must not snap them back to rest.
    var gestureActive = false
    /// Puts `spaceID` on screen before returning. False when the stage has no size yet.
    var reveal: ((UUID) -> Bool)?
    /// Finger down. `offset` matches the sidebar: positive reveals the previous space.
    /// The page does not move; its opacity follows `offset / width`.
    var track: ((_ anchor: UUID, _ offset: CGFloat, _ width: CGFloat) -> Void)?
    /// Finger up. Ease the cross-fade toward `offset` (0, +width, or −width).
    /// `velocity` belongs to the sidebar spring. The page fade does not take it.
    var settle: ((_ offset: CGFloat, _ width: CGFloat, _ velocity: CGFloat) -> Void)?
    var endGesture: (() -> Void)?
    /// Attach web views created by prewarm.
    var sync: (() -> Void)?
    var isShowing: ((UUID) -> Bool)?
}

/// Input → content-visible. Signposts plus a line when `MYBROWSER_SPACE_SWITCH_LOG` is a file path.
enum SpaceSwitchTrace {
    private static let logger = Logger(subsystem: "ch.marvinvr.mybrowser", category: "SpaceSwitch")
    private static let signposter = OSSignposter(logger: logger)
    private static let origin = ContinuousClock.now
    private static let writeQueue = DispatchQueue(label: "ch.marvinvr.mybrowser.space-switch-log")

    static func begin(_ kind: String) -> ContinuousClock.Instant {
        signposter.emitEvent("SpaceSwitchBegin", "\(kind, privacy: .public)")
        return ContinuousClock.now
    }

    static func end(_ start: ContinuousClock.Instant, _ kind: String, _ detail: String) {
        let elapsed = milliseconds(since: start)
        let text = String(format: "%.3f", elapsed)
        signposter.emitEvent("SpaceSwitch", "\(kind, privacy: .public) \(text, privacy: .public)ms \(detail, privacy: .public)")
        logger.info("SpaceSwitch \(kind, privacy: .public) \(text, privacy: .public)ms \(detail, privacy: .public)")
        write("\(String(format: "%.3f", milliseconds(since: origin))) \(kind) \(text)ms \(detail)")
    }

    static func mark(_ message: String) {
        let text = String(format: "%.3f", milliseconds(since: origin))
        signposter.emitEvent("SpaceSwitchMark", "\(message, privacy: .public)")
        logger.info("SpaceSwitch mark \(text, privacy: .public)ms \(message, privacy: .public)")
        write("\(text) mark \(message)")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func write(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["MYBROWSER_SPACE_SWITCH_LOG"],
              !path.isEmpty else { return }
        writeQueue.async {
            let url = URL(fileURLWithPath: path)
            let data = Data((line + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: path) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: url)
            }
        }
    }
}

/// One AppKit view for every Space's selected page.
///
/// Neighbours sit under the current page (same frame, so WebKit has painted them).
/// A switch cross-fades: the incoming page fades in on top of the opaque outgoing page,
/// so the card background never shows through and nothing slides sideways. A click starts
/// that fade on the turn the web view is attached. A sidebar swipe ties the opacity to
/// the finger and eases the rest of the way on release.
struct SpaceContentRepresentable: NSViewRepresentable {
    var model: BrowserModel
    var hidden: Bool
    var trafficClearance: CGFloat
    var extensions: ExtensionManager

    func makeNSView(context: Context) -> SpaceContentStage {
        let view = SpaceContentStage()
        view.bind(model)
        view.configure(extensions: extensions, trafficClearance: trafficClearance)
        return view
    }

    func updateNSView(_ view: SpaceContentStage, context: Context) {
        view.bind(model)
        view.configure(extensions: extensions, trafficClearance: trafficClearance)
        view.syncFromModel()
        view.isHidden = hidden
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpaceContentStage, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
    }
}

@MainActor
final class SpaceContentStage: NSView {
    private weak var model: BrowserModel?
    private var extensions: ExtensionManager?
    private var trafficClearance: CGFloat = SidebarMetrics.minimumTrafficClearance
    private struct Slot {
        var canvas: SplitCanvasView
        var signature: String
    }

    private var slots: [UUID: Slot] = [:]
    /// Full cross-fade. Ease-in-out, independent of the sidebar's 0.22s spring.
    static let fadeDuration: CFTimeInterval = 0.20
    /// Space the gesture started on. Nil when the stage is at rest or a click fade is running.
    private var anchorID: UUID?
    private var restingID: UUID?
    /// Click or shortcut target. Nil while a swipe picks the incoming space from `progress`.
    private var fadeTarget: UUID?
    /// Sidebar offset / column width while a finger is down. Positive reveals the previous space.
    /// During a click fade this runs from 0 to 1.
    private var progress: CGFloat = 0
    private var settling = false
    private var settleFrom: CGFloat = 0
    private var settleTo: CGFloat = 0
    private var settleStart: CFTimeInterval = 0
    /// Last logged opacity band, so a fade writes a handful of lines instead of every frame.
    private var loggedFadeBand = -2
    private let sampler = SpaceContentSampler()

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        placeSlots()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func bind(_ model: BrowserModel) {
        self.model = model
        let stage = self
        model.spaceContent.reveal = { [weak stage] id in stage?.reveal(id) ?? false }
        model.spaceContent.track = { [weak stage] anchor, offset, width in
            stage?.track(anchor: anchor, offset: offset, width: width)
        }
        model.spaceContent.settle = { [weak stage] offset, width, velocity in
            stage?.beginSettle(offset: offset, width: width, velocity: velocity)
        }
        model.spaceContent.endGesture = { [weak stage] in stage?.endGesture() }
        model.spaceContent.sync = { [weak stage] in stage?.syncFromModel() }
        model.spaceContent.isShowing = { [weak stage] id in stage?.isShowing(id) ?? false }
    }

    /// Pane toolbars need the extension manager and the traffic-light inset. Push both into
    /// canvases that are already on screen when either value changes.
    func configure(extensions: ExtensionManager, trafficClearance: CGFloat) {
        let changed = self.extensions !== extensions || self.trafficClearance != trafficClearance
        self.extensions = extensions
        self.trafficClearance = trafficClearance
        guard changed, let model else { return }
        for (id, slot) in slots {
            guard let itemID = model.session.selectedItemBySpace[id],
                  let content = model.displayedContent(for: itemID) else { continue }
            slot.canvas.attach(
                model: model,
                extensions: extensions,
                content: content,
                trafficClearance: trafficClearance
            )
        }
    }

    /// Discrete switch. The target's web view is attached before this returns, then fades in.
    func reveal(_ id: UUID) -> Bool {
        guard anchorID == nil else { return isShowing(id) }
        isHidden = false
        ensureSlot(id)
        let from: UUID?
        if settling, progress > 0.5, let fadeTarget {
            from = fadeTarget
        } else {
            from = restingID
        }
        stopSettle()
        if from == nil || from == id || slots[id] == nil || slots[from ?? id] == nil {
            restingID = id
            fadeTarget = nil
            progress = 0
            placeSlots()
            layoutSubtreeIfNeeded()
            return isShowing(id)
        }
        restingID = from
        fadeTarget = id
        progress = 0
        startFade(from: 0, to: 1)
        placeSlots()
        layoutSubtreeIfNeeded()
        return isShowing(id)
    }

    func track(anchor: UUID, offset: CGFloat, width: CGFloat) {
        let restarted = anchorID != anchor || fadeTarget != nil
        stopSettle()
        if restarted {
            loggedFadeBand = -2
        }
        fadeTarget = nil
        anchorID = anchor
        progress = width > 1 ? offset / width : 0
        ensureSlot(anchor)
        ensureNeighbours(of: anchor)
        placeSlots()
    }

    func beginSettle(offset: CGFloat, width: CGFloat, velocity _: CGFloat) {
        fadeTarget = nil
        let target = width > 1 ? offset / width : 0
        guard abs(progress - target) > 0.0008 else {
            progress = target
            finishFade(elapsed: 0)
            return
        }
        startFade(from: progress, to: target)
        placeSlots()
    }

    func endGesture() {
        // The sidebar spring can finish first. The page fade keeps its own clock.
        guard !settling else { return }
        anchorID = nil
        fadeTarget = nil
        progress = 0
        if let model {
            restingID = model.selectedSpaceID
        }
        placeSlots()
    }

    func syncFromModel() {
        guard let model else { return }
        let selected = model.selectedSpaceID
        if anchorID == nil, !settling {
            restingID = selected
        }
        ensureSlot(selected)
        if let center = anchorID ?? restingID {
            ensureNeighbours(of: center)
        }
        let live = Set(model.library.orderedSpaces.map(\.id))
        for id in slots.keys where !live.contains(id) {
            slots[id]?.canvas.removeFromSuperview()
            slots[id] = nil
        }
        placeSlots()
    }

    /// At rest, only the front page counts. During a swipe, a sliver of the incoming page counts:
    /// the commit line is 30% of the column, and the page is already on screen there.
    func isShowing(_ id: UUID) -> Bool {
        let fraction = visibleFraction(id)
        if anchorID != nil || settling {
            return fraction > 0.02
        }
        return fraction > 0.9
    }

    private func visibleFraction(_ id: UUID) -> CGFloat {
        guard !isHidden, let canvas = slots[id]?.canvas, !canvas.isHidden, bounds.width > 2, bounds.height > 2 else {
            return 0
        }
        let visible = canvas.frame.intersection(bounds)
        guard visible.height > bounds.height * 0.5 else { return 0 }
        if anchorID == nil, !settling, subviews.last !== canvas {
            return 0
        }
        return visible.width / bounds.width
    }

    private func startFade(from: CGFloat, to: CGFloat) {
        settleFrom = from
        settleTo = to
        settleStart = CACurrentMediaTime()
        settling = true
        loggedFadeBand = -2
        sampler.start(on: self) { [weak self] in
            MainActor.assumeIsolated {
                self?.stepSettle()
            }
        }
    }

    private func stepSettle() {
        let elapsed = CACurrentMediaTime() - settleStart
        let duration = Self.fadeDuration
        let t = duration > 0 ? min(1, elapsed / duration) : 1
        let eased = Self.easeInOut(CGFloat(t))
        progress = settleFrom + (settleTo - settleFrom) * eased
        if t >= 1 {
            progress = settleTo
            placeSlots()
            finishFade(elapsed: elapsed)
            return
        }
        placeSlots()
    }

    /// Cubic ease-in-out on the unit interval.
    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        let x = min(max(t, 0), 1)
        if x < 0.5 {
            return 4 * x * x * x
        }
        let f = -2 * x + 2
        return 1 - (f * f * f) / 2
    }

    private func finishFade(elapsed: CFTimeInterval) {
        stopSettle()
        let landed = model?.selectedSpaceID ?? fadeTarget ?? restingID
        anchorID = nil
        fadeTarget = nil
        progress = 0
        restingID = landed
        placeSlots()
        SpaceSwitchTrace.mark(String(format: "content-settled %.0fms", max(0, elapsed) * 1000))
    }

    private func stopSettle() {
        settling = false
        sampler.stop()
    }

    private func ensureNeighbours(of id: UUID) {
        guard let model else { return }
        let spaces = model.library.orderedSpaces
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        for neighbor in [index - 1, index + 1] where spaces.indices.contains(neighbor) {
            let nid = spaces[neighbor].id
            if model.session.selectedItemBySpace[nid] != nil {
                ensureSlot(nid)
            }
        }
    }

    private func ensureSlot(_ spaceID: UUID) {
        guard let model else { return }
        guard let itemID = model.session.selectedItemBySpace[spaceID],
              let content = model.displayedContent(for: itemID) else {
            if let slot = slots.removeValue(forKey: spaceID) {
                slot.canvas.removeFromSuperview()
            }
            return
        }
        guard let extensions else { return }
        let signature = Self.signature(content)
        if var slot = slots[spaceID] {
            if slot.signature != signature {
                slot.canvas.attach(
                    model: model,
                    extensions: extensions,
                    content: content,
                    trafficClearance: trafficClearance
                )
                slot.signature = signature
                slots[spaceID] = slot
            }
            return
        }
        let canvas = SplitCanvasView(frame: bounds)
        canvas.attach(
            model: model,
            extensions: extensions,
            content: content,
            trafficClearance: trafficClearance
        )
        addSubview(canvas)
        slots[spaceID] = Slot(canvas: canvas, signature: signature)
    }

    private func placeSlots() {
        let width = bounds.width
        let height = bounds.height
        guard width > 2, height > 2 else { return }
        let frame = bounds
        let fading = anchorID != nil || settling
        // Opacity changes are sampled. An implicit 0.25s fade would lag the finger.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for slot in slots.values {
            slot.canvas.isHidden = false
            if slot.canvas.frame != frame {
                slot.canvas.frame = frame
            }
            if !fading {
                slot.canvas.alphaValue = 1
            }
        }
        if !fading {
            if let center = restingID, let top = slots[center]?.canvas, subviews.last !== top {
                addSubview(top)
            }
            return
        }
        let outgoing = anchorID ?? restingID
        let incoming = incomingID(around: outgoing)
        let coverage = coverage(for: incoming)
        // The outgoing page stays opaque. Fading it as well would show the card background.
        for (id, slot) in slots where id != incoming {
            slot.canvas.alphaValue = 1
        }
        stack(outgoing: outgoing, incoming: incoming, coverage: coverage)
        noteFade(coverage: coverage, incoming: incoming)
    }

    /// Incoming page for this frame. A click names it. A swipe takes the neighbour the finger is opening.
    private func incomingID(around outgoing: UUID?) -> UUID? {
        if let fadeTarget, fadeTarget != outgoing, slots[fadeTarget] != nil {
            return fadeTarget
        }
        guard fadeTarget == nil, let outgoing, progress != 0, let model else { return nil }
        let spaces = model.library.orderedSpaces
        guard let index = spaces.firstIndex(where: { $0.id == outgoing }) else { return nil }
        if progress > 0, index > 0 { return spaces[index - 1].id }
        if progress < 0, index + 1 < spaces.count { return spaces[index + 1].id }
        return nil
    }

    private func coverage(for incoming: UUID?) -> CGFloat {
        guard incoming != nil else { return 0 }
        if fadeTarget != nil {
            return min(max(progress, 0), 1)
        }
        return min(max(abs(progress), 0), 1)
    }

    /// Incoming page in front, outgoing page directly under it. Both fill the card.
    private func stack(outgoing: UUID?, incoming: UUID?, coverage: CGFloat) {
        let showIncoming = incoming != nil && coverage > 0 && incoming != outgoing
        if showIncoming, let incoming, let front = slots[incoming]?.canvas {
            front.alphaValue = coverage
            if let outgoing, outgoing != incoming, let back = slots[outgoing]?.canvas {
                back.alphaValue = 1
                if subviews.last !== front || subviews.dropLast().last !== back {
                    addSubview(back)
                    addSubview(front)
                }
            } else if subviews.last !== front {
                addSubview(front)
            }
            return
        }
        if let outgoing, let back = slots[outgoing]?.canvas {
            back.alphaValue = 1
            if subviews.last !== back {
                addSubview(back)
            }
        }
    }

    private func noteFade(coverage: CGFloat, incoming: UUID?) {
        let band = Int((min(max(coverage, 0), 1) * 4).rounded(.down))
        guard band != loggedFadeBand else { return }
        loggedFadeBand = band
        let x = incoming.flatMap { slots[$0]?.canvas.frame.origin.x } ?? 0
        SpaceSwitchTrace.mark(String(format: "content-fade in=%.2f out=1.00 x=%.0f", coverage, x))
    }

    private static func signature(_ content: DisplayedContent) -> String {
        let panes = content.panes.map { pane in
            let fraction = pane.fraction.map { String(format: "%.4f", $0) } ?? "-"
            return "\(pane.id.uuidString):\(fraction):\(pane.tab.isLoaded)"
        }.joined(separator: ",")
        return "\(content.itemID.uuidString)|\(content.focusedID.uuidString)|\(content.axis)|\(panes)"
    }
}

/// Steps the content cross-fade. This hosting view's display link never fires, so a common-mode
/// timer does. Common mode keeps the callbacks running inside a trackpad tracking loop.
nonisolated private final class SpaceContentSampler: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Timer?
    private var onFire: @Sendable () -> Void = {}

    @MainActor
    func start(on view: NSView, _ block: @escaping @Sendable () -> Void) {
        _ = view
        stop()
        lock.lock()
        onFire = block
        lock.unlock()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let installed = timer
        timer = nil
        onFire = {}
        lock.unlock()
        installed?.invalidate()
    }

    private func fire() {
        lock.lock()
        let block = onFire
        lock.unlock()
        block()
    }

    deinit { stop() }
}

#if DEBUG
/// Feeds a synthetic sidebar swipe through the live tracker. Measurement only.
enum SpaceSwipeDebugInject {
    static var send: (@MainActor (SpaceSwipeSample) -> Void)?
}
#endif
