import CoreGraphics
import Foundation

/// One scroll-wheel sample. `deltaX` uses AppKit's sign: positive moves content to the right.
nonisolated struct SpaceSwipeSample: Equatable, Sendable {
    var phase: SpaceSwipePhase
    var deltaX: CGFloat
    var deltaY: CGFloat
    var time: TimeInterval
    /// False when the pointer is outside the sidebar. An in-progress gesture still receives those samples.
    var inside: Bool

    init(
        phase: SpaceSwipePhase,
        deltaX: CGFloat,
        deltaY: CGFloat,
        time: TimeInterval,
        inside: Bool = true
    ) {
        self.phase = phase
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.time = time
        self.inside = inside
    }
}

nonisolated enum SpaceSwipePhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case cancelled
    /// Inertial tail after the fingers lift. `ended` is the last momentum sample.
    case momentum(ended: Bool)
    /// Phaseless scroll, such as a mouse wheel. Never starts a space switch.
    case other

    /// Maps `NSEvent.phase` / `momentumPhase` raw values. Momentum wins when both are set,
    /// which is the lift event on some trackpads; the tracker still settles if it was tracking.
    static func from(phaseRaw: UInt, momentumRaw: UInt) -> SpaceSwipePhase {
        let began: UInt = 1 << 0
        let stationary: UInt = 1 << 1
        let changed: UInt = 1 << 2
        let ended: UInt = 1 << 3
        let cancelled: UInt = 1 << 4
        let mayBegin: UInt = 1 << 5

        if (momentumRaw & cancelled) != 0 { return .cancelled }
        if momentumRaw != 0 {
            let done = (momentumRaw & (ended | cancelled)) != 0
            return .momentum(ended: done)
        }
        if (phaseRaw & cancelled) != 0 { return .cancelled }
        if (phaseRaw & ended) != 0 { return .ended }
        if (phaseRaw & (began | mayBegin)) != 0 { return .began }
        if (phaseRaw & (changed | stationary)) != 0 { return .changed }
        return .other
    }
}

nonisolated enum SpaceSwipeAction: Equatable, Sendable {
    case none
    case selectPrevious
    case selectNext
}

nonisolated enum SpaceSwipeUpdate: Equatable, Sendable {
    /// Not this gesture. The scroll view keeps the event.
    case passthrough
    /// Claimed. `offset` is the sidebar translation (positive reveals the previous space).
    case tracking(offset: CGFloat)
    /// Fingers up. Animate to `offset`, then run `action` (0 and `.none` spring back).
    case settle(offset: CGFloat, action: SpaceSwipeAction)
    /// Part of a claimed gesture whose translation must not change. Momentum after the decision.
    case consume
}

/// Turns trackpad scroll samples into a sidebar translation and a commit or cancel.
///
/// Horizontal dominance is decided once, when travel passes `axisSlop`: `|dx| > |dy| * dominanceRatio`.
/// A claimed gesture tracks the finger 1:1 until the missing neighbour, where it rubber-bands.
/// Release commits when the finger has crossed `commitFraction` of `width` or flicked past `flickVelocity`.
nonisolated struct SpaceSwipeTracker: Sendable {
    var canGoPrevious = false
    var canGoNext = false
    var width: CGFloat = 1

    static let defaultCommitFraction: CGFloat = 0.30
    var commitFraction: CGFloat = defaultCommitFraction
    /// Points per second. A flick at least this fast commits without crossing `commitFraction`.
    var flickVelocity: CGFloat = 1100
    var dominanceRatio: CGFloat = 1.5
    /// Travel, in points, before the axis is chosen.
    var axisSlop: CGFloat = 2
    var velocityWindow: TimeInterval = 0.09

    /// Translation the sidebar should show. Rubber-banded at the ends.
    private(set) var offset: CGFloat = 0

    private enum Mode: Equatable {
        case idle
        case deciding
        case tracking
        case coasting
        case rejected
    }

    private var mode: Mode = .idle
    private var rawOffset: CGFloat = 0
    private var pendingX: CGFloat = 0
    private var pendingAbsX: CGFloat = 0
    private var pendingAbsY: CGFloat = 0
    private var samples: [(time: TimeInterval, deltaX: CGFloat)] = []
    private var sawMomentum = false
    private var momentumFinished = false
    private var viewSettled = false

    /// The spring finished. Momentum that is still arriving stays swallowed until it ends.
    mutating func noteSettleFinished() {
        viewSettled = true
        guard mode == .coasting, momentumFinished else { return }
        goIdle()
    }

    mutating func handle(_ sample: SpaceSwipeSample) -> SpaceSwipeUpdate {
        if let ignored = ignoredUpdate(sample) { return ignored }

        switch sample.phase {
        case .other:
            return .passthrough
        case .momentum(let ended):
            return handleMomentum(ended: ended)
        case .cancelled:
            return handleCancelled()
        case .began:
            return beginGesture(sample)
        case .changed:
            if mode == .idle || mode == .coasting {
                return beginGesture(sample)
            }
            return accumulate(sample)
        case .ended:
            return handleEnded(sample)
        }
    }

    /// App deactivation or the window resigning key. A finger that is still down settles
    /// (commit or spring back) instead of leaving the column where it was.
    mutating func interrupt() -> SpaceSwipeUpdate {
        switch mode {
        case .tracking:
            return decide()
        case .deciding, .rejected:
            let stuck = offset != 0
            goIdle()
            return stuck ? .settle(offset: 0, action: .none) : .passthrough
        case .coasting:
            return .consume
        case .idle:
            return .passthrough
        }
    }

    /// Events outside the sidebar never start a gesture. An active drag still tracks if the
    /// pointer slides off the column. A new touch outside settles a drag in progress, so the
    /// column cannot stay parked at the last offset. A new touch outside ends a coast so the page can swipe.
    private mutating func ignoredUpdate(_ sample: SpaceSwipeSample) -> SpaceSwipeUpdate? {
        guard !sample.inside else { return nil }
        switch mode {
        case .idle:
            return .passthrough
        case .tracking:
            if case .began = sample.phase {
                return decide()
            }
            return nil
        case .deciding:
            if case .began = sample.phase {
                goIdle()
                return .passthrough
            }
            return nil
        case .coasting:
            switch sample.phase {
            case .momentum, .ended, .cancelled:
                return nil
            default:
                goIdle()
                return .passthrough
            }
        case .rejected:
            if case .began = sample.phase {
                goIdle()
                return .passthrough
            }
            return nil
        }
    }

    /// Neighbour the finger has crossed the commit line toward. Dead ends stay `.none`.
    static func armedDetent(
        offset: CGFloat,
        width: CGFloat,
        commitFraction: CGFloat = defaultCommitFraction,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) -> SpaceSwipeAction {
        guard width >= 1 else { return .none }
        let line = width * commitFraction
        if offset >= line, canGoPrevious { return .selectPrevious }
        if offset <= -line, canGoNext { return .selectNext }
        return .none
    }

    /// Diminishing translation for `distance` points of overscroll along `dimension`.
    static func rubberBand(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let axis = max(dimension, 1)
        let traveled = max(0, distance)
        let stiffness: CGFloat = 0.55
        let limit = axis * 0.45
        return (1 - (1 / ((traveled * stiffness / axis) + 1))) * limit
    }

    private mutating func beginGesture(_ sample: SpaceSwipeSample) -> SpaceSwipeUpdate {
        let interrupting = mode == .tracking || mode == .coasting
        mode = .deciding
        rawOffset = 0
        pendingX = 0
        pendingAbsX = 0
        pendingAbsY = 0
        samples.removeAll()
        sawMomentum = false
        momentumFinished = false
        viewSettled = false
        let update = accumulate(sample)
        if interrupting, case .passthrough = update {
            offset = 0
            return .tracking(offset: 0)
        }
        return update
    }

    private mutating func accumulate(_ sample: SpaceSwipeSample) -> SpaceSwipeUpdate {
        switch mode {
        case .rejected:
            return .passthrough
        case .deciding:
            pendingX += sample.deltaX
            pendingAbsX += abs(sample.deltaX)
            pendingAbsY += abs(sample.deltaY)
            noteVelocity(sample)
            guard pendingAbsX + pendingAbsY >= axisSlop else { return .passthrough }
            if pendingAbsX > pendingAbsY * dominanceRatio {
                mode = .tracking
                rawOffset = pendingX
                offset = present(rawOffset)
                return .tracking(offset: offset)
            }
            mode = .rejected
            return .passthrough
        case .tracking:
            rawOffset += sample.deltaX
            noteVelocity(sample)
            offset = present(rawOffset)
            return .tracking(offset: offset)
        case .idle, .coasting:
            return .passthrough
        }
    }

    private mutating func handleEnded(_ sample: SpaceSwipeSample) -> SpaceSwipeUpdate {
        switch mode {
        case .deciding:
            let update = accumulate(sample)
            if mode == .tracking { return decide() }
            goIdle()
            return update == .passthrough ? .passthrough : update
        case .tracking:
            _ = accumulate(sample)
            return decide()
        case .rejected:
            goIdle()
            return .passthrough
        case .coasting:
            return .consume
        case .idle:
            return .passthrough
        }
    }

    private mutating func handleCancelled() -> SpaceSwipeUpdate {
        switch mode {
        case .tracking:
            return settle(offset: 0, action: .none)
        case .deciding, .rejected:
            goIdle()
            return .passthrough
        case .coasting:
            return .consume
        case .idle:
            return .passthrough
        }
    }

    private mutating func handleMomentum(ended: Bool) -> SpaceSwipeUpdate {
        switch mode {
        case .tracking:
            let update = decide()
            sawMomentum = true
            if ended {
                momentumFinished = true
                if viewSettled { goIdle() }
            }
            return update
        case .coasting:
            sawMomentum = true
            if ended {
                momentumFinished = true
                if viewSettled { goIdle() }
            }
            return .consume
        case .rejected:
            if ended { goIdle() }
            return .passthrough
        case .deciding:
            goIdle()
            return .passthrough
        case .idle:
            return .passthrough
        }
    }

    private mutating func decide() -> SpaceSwipeUpdate {
        let speed = velocity
        let threshold = width >= 1 ? width * commitFraction : .greatestFiniteMagnitude
        let flicked = abs(speed) >= flickVelocity
        var action: SpaceSwipeAction = .none
        var flungBack = false

        if flicked {
            let sameDirection = rawOffset == 0 || (rawOffset > 0) == (speed > 0)
            let tiny = abs(rawOffset) < 12
            if sameDirection || tiny {
                if speed > 0, canGoPrevious {
                    action = .selectPrevious
                } else if speed < 0, canGoNext {
                    action = .selectNext
                }
            } else {
                flungBack = true
            }
        }
        if action == .none, !flungBack {
            if rawOffset >= threshold, canGoPrevious {
                action = .selectPrevious
            } else if rawOffset <= -threshold, canGoNext {
                action = .selectNext
            }
        }

        let distance = max(width, 1)
        let target: CGFloat
        switch action {
        case .none: target = 0
        case .selectPrevious: target = distance
        case .selectNext: target = -distance
        }
        return settle(offset: target, action: action)
    }

    private mutating func settle(offset target: CGFloat, action: SpaceSwipeAction) -> SpaceSwipeUpdate {
        rawOffset = target
        offset = target
        mode = .coasting
        samples.removeAll()
        sawMomentum = false
        momentumFinished = false
        viewSettled = false
        return .settle(offset: target, action: action)
    }

    private func present(_ raw: CGFloat) -> CGFloat {
        let axis = max(width, 1)
        if raw > 0, !canGoPrevious { return Self.rubberBand(raw, dimension: axis) }
        if raw < 0, !canGoNext { return -Self.rubberBand(-raw, dimension: axis) }
        if raw > axis { return axis + Self.rubberBand(raw - axis, dimension: axis) }
        if raw < -axis { return -axis - Self.rubberBand(-raw - axis, dimension: axis) }
        return raw
    }

    private mutating func noteVelocity(_ sample: SpaceSwipeSample) {
        guard sample.deltaX != 0 else { return }
        samples.append((sample.time, sample.deltaX))
        let cutoff = sample.time - velocityWindow
        samples.removeAll { $0.time < cutoff }
    }

    private var velocity: CGFloat {
        guard let first = samples.first, let last = samples.last, samples.count >= 2, last.time > first.time else {
            return 0
        }
        let distance = samples.reduce(CGFloat(0)) { $0 + $1.deltaX }
        return distance / CGFloat(last.time - first.time)
    }

    private mutating func goIdle() {
        mode = .idle
        rawOffset = 0
        offset = 0
        pendingX = 0
        pendingAbsX = 0
        pendingAbsY = 0
        samples.removeAll()
        sawMomentum = false
        momentumFinished = false
        viewSettled = false
    }
}
