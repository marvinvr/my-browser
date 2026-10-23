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
    var track: ((_ anchor: UUID, _ offset: CGFloat, _ width: CGFloat) -> Void)?
    /// Finger up. Animate from the current offset toward `offset` (0, +width, or −width).
    /// `velocity` is points per second, already clamped to the direction of that move.
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
/// Neighbours sit under the current page (same frame, so WebKit has painted them) and
/// slide sideways while a sidebar swipe is on the finger. A click reorders the target
/// to the front before `selectSpace` returns.
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
    /// Space the gesture started on. Nil when the stage is at rest.
    private var anchorID: UUID?
    private var restingID: UUID?
    /// Sidebar offset / column width. Positive reveals the previous space.
    private var progress: CGFloat = 0
    private var settling = false
    private var settleFrom: CGFloat = 0
    private var settleTo: CGFloat = 0
    /// Progress units per second. Points per second divided by the column width.
    private var settleVelocity: CGFloat = 0
    private var settleStart: CFTimeInterval = 0
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

    /// Discrete switch. The target's web view is in front before this returns.
    func reveal(_ id: UUID) -> Bool {
        guard anchorID == nil, !settling else { return isShowing(id) }
        isHidden = false
        restingID = id
        ensureSlot(id)
        progress = 0
        placeSlots()
        layoutSubtreeIfNeeded()
        return isShowing(id)
    }

    func track(anchor: UUID, offset: CGFloat, width: CGFloat) {
        stopSettle()
        anchorID = anchor
        progress = width > 1 ? offset / width : 0
        ensureSlot(anchor)
        ensureNeighbours(of: anchor)
        placeSlots()
    }

    func beginSettle(offset: CGFloat, width: CGFloat, velocity: CGFloat) {
        let target = width > 1 ? offset / width : 0
        settleFrom = progress
        settleTo = target
        settleVelocity = width > 1 ? velocity / width : 0
        settleStart = CACurrentMediaTime()
        settling = true
        sampler.start(on: self) { [weak self] in
            MainActor.assumeIsolated {
                self?.stepSettle()
            }
        }
    }

    func endGesture() {
        stopSettle()
        anchorID = nil
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

    private func stepSettle() {
        let elapsed = CACurrentMediaTime() - settleStart
        let delta = settleTo - settleFrom
        // Same unit spring as the sidebar. Duration does not depend on how far the page still has to go.
        let relative = delta == 0 ? 0 : Double(settleVelocity / delta)
        let unit = SpaceSwipeMotion.spring.value(
            target: 1.0,
            initialVelocity: relative,
            time: elapsed
        )
        progress = settleFrom + delta * unit
        if elapsed >= SpaceSwipeMotion.duration || abs(progress - settleTo) < 0.0008 {
            progress = settleTo
            stopSettle()
            SpaceSwitchTrace.mark(String(format: "content-settled %.0fms", elapsed * 1000))
        }
        placeSlots()
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
        let center = anchorID ?? restingID
        let sliding = anchorID != nil || settling
        if !sliding, let center, let top = slots[center]?.canvas {
            for slot in slots.values {
                slot.canvas.isHidden = false
                if slot.canvas.frame != bounds {
                    slot.canvas.frame = bounds
                }
            }
            if subviews.last !== top {
                addSubview(top)
            }
            return
        }
        guard let center, let model else { return }
        let spaces = model.library.orderedSpaces
        let index = spaces.firstIndex { $0.id == center } ?? 0
        let previous = index > 0 ? spaces[index - 1].id : nil
        let next = index + 1 < spaces.count ? spaces[index + 1].id : nil
        let shown: Set<UUID> = [previous, center, next].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
        for (id, slot) in slots {
            guard shown.contains(id) else {
                slot.canvas.isHidden = true
                continue
            }
            slot.canvas.isHidden = false
            let shift: CGFloat
            if id == previous {
                shift = progress - 1
            } else if id == next {
                shift = progress + 1
            } else {
                shift = progress
            }
            let frame = CGRect(x: shift * width, y: 0, width: width, height: height)
            if slot.canvas.frame != frame {
                slot.canvas.frame = frame
            }
        }
    }

    private static func signature(_ content: DisplayedContent) -> String {
        let panes = content.panes.map { pane in
            let fraction = pane.fraction.map { String(format: "%.4f", $0) } ?? "-"
            return "\(pane.id.uuidString):\(fraction):\(pane.tab.isLoaded)"
        }.joined(separator: ",")
        return "\(content.itemID.uuidString)|\(content.focusedID.uuidString)|\(content.axis)|\(panes)"
    }
}

/// Steps the content spring. This hosting view's display link never fires, so a common-mode
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
