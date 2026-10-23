import CoreGraphics
import Foundation

/// Layout numbers for a split in the content card.
enum SplitMetrics {
    static let gap: CGFloat = 6
    static let minPane: CGFloat = 240
    static let cornerRadius: CGFloat = 8
    /// Drag target centered on the gap. Wider than the gap so the pointer can grab it.
    static let dividerHit: CGFloat = 10
    /// Outer fraction of the card height that starts a stacked split.
    /// The rest of the card is the left and right halves.
    static let stackEdgeFraction: CGFloat = 0.20
}

/// Where a sidebar item will sit when it is dropped on the content card.
enum SplitDropZone: Equatable {
    case leading
    case trailing
    case top
    case bottom

    /// The dropped page is the first pane (left, or top).
    var placesDraggedFirst: Bool {
        self == .leading || self == .top
    }

    var isVertical: Bool {
        self == .top || self == .bottom
    }
}

/// Which halves the pointer can choose. A new split offers a stack near the top and bottom.
enum SplitDropMode: Equatable {
    /// Top and bottom bands stack. Between them, the card is the left and right halves.
    case choose
    /// The whole card is the left and right halves.
    case horizontal
    /// The whole card is the top and bottom halves.
    case vertical
}

/// One pane's extent along the split axis. Origin is the leading edge.
struct SplitSpan: Equatable {
    var origin: CGFloat
    var length: CGFloat
}

enum SplitGeometry {
    /// Shares that sum to 1. A missing share makes every pane equal.
    static func shares(from fractions: [Double?]) -> [Double] {
        let count = fractions.count
        guard count > 0 else { return [] }
        let resolved = fractions.map { value -> Double? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        guard resolved.allSatisfy({ $0 != nil }) else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        let values = resolved.map { $0 ?? 0 }
        let sum = values.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1 / Double(count), count: count) }
        return values.map { $0 / sum }
    }

    /// Pixel lengths along the axis. `available` already excludes gaps.
    /// Each pane keeps `minimum` unless the card cannot fit that, in which case the panes share what is left.
    static func lengths(shares: [Double], available: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let count = shares.count
        guard count > 0 else { return [] }
        guard available > 1 else { return Array(repeating: 0, count: count) }
        let floor = min(max(minimum, 0), available / CGFloat(count))
        var lengths = Array(repeating: floor, count: count)
        var locked = Array(repeating: false, count: count)
        let weights = shares.map { CGFloat(max($0, 0)) }

        for _ in 0..<count {
            let used = zip(lengths, locked).reduce(CGFloat(0)) { partial, pair in
                partial + (pair.1 ? floor : 0)
            }
            let flexible = zip(weights, locked).reduce(CGFloat(0)) { partial, pair in
                partial + (pair.1 ? 0 : pair.0)
            }
            let remaining = available - used
            guard flexible > 0, remaining >= 0 else { break }
            var clamped = false
            for index in lengths.indices where !locked[index] {
                let proposed = remaining * weights[index] / flexible
                if proposed < floor - 0.1 {
                    locked[index] = true
                    lengths[index] = floor
                    clamped = true
                } else {
                    lengths[index] = proposed
                }
            }
            if !clamped { break }
        }
        return lengths
    }

    /// Pane spans from the leading edge. Gaps sit between them and are not part of a span.
    static func spans(shares: [Double], total: CGFloat, gap: CGFloat, minimum: CGFloat) -> [SplitSpan] {
        let count = shares.count
        guard count > 0, total > 0 else { return [] }
        let available = max(0, total - gap * CGFloat(max(count - 1, 0)))
        let sizes = lengths(shares: shares, available: available, minimum: minimum)
        var cursor: CGFloat = 0
        return sizes.map { length in
            let span = SplitSpan(origin: cursor, length: max(0, length))
            cursor += length + gap
            return span
        }
    }

    /// `translation` moves the divider toward the trailing edge. The two panes beside it trade space.
    /// Other panes stay put. No pane goes under `minimum` unless the card is already smaller than that.
    static func sharesByDragging(
        start: [Double],
        divider: Int,
        translation: CGFloat,
        available: CGFloat,
        minimum: CGFloat
    ) -> [Double] {
        guard start.indices.contains(divider), start.indices.contains(divider + 1), available > 1 else {
            return start
        }
        let floor = min(max(minimum, 0), available / CGFloat(start.count))
        let minShare = Double(floor / available)
        var next = start
        let delta = Double(translation / available)
        let roomTrailing = next[divider + 1] - minShare
        let roomLeading = next[divider] - minShare
        let applied = min(max(delta, -roomLeading), roomTrailing)
        next[divider] += applied
        next[divider + 1] -= applied
        return next
    }

    /// The half under `point`. Nil when the card has no size or the point is outside it.
    ///
    /// `.choose` uses the top and bottom `stackEdgeFraction` of the height for a stacked split.
    /// Everywhere else is the left or right half, including the middle of the card.
    /// `.horizontal` and `.vertical` split the whole card in two along that axis.
    static func dropZone(
        at point: CGPoint,
        size: CGSize,
        mode: SplitDropMode,
        stackEdgeFraction: CGFloat = SplitMetrics.stackEdgeFraction
    ) -> SplitDropZone? {
        guard size.width > 1, size.height > 1 else { return nil }
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return nil }
        switch mode {
        case .horizontal:
            return point.x < size.width / 2 ? .leading : .trailing
        case .vertical:
            return point.y < size.height / 2 ? .top : .bottom
        case .choose:
            let fraction = min(max(stackEdgeFraction, 0), 0.49)
            let band = size.height * fraction
            if point.y <= band { return .top }
            if point.y >= size.height - band { return .bottom }
            return point.x < size.width / 2 ? .leading : .trailing
        }
    }

    /// The half of the card the dropped page will occupy.
    static func previewRect(for zone: SplitDropZone, size: CGSize) -> CGRect {
        let width = max(size.width, 0)
        let height = max(size.height, 0)
        switch zone {
        case .leading:
            return CGRect(x: 0, y: 0, width: width / 2, height: height)
        case .trailing:
            return CGRect(x: width / 2, y: 0, width: width / 2, height: height)
        case .top:
            return CGRect(x: 0, y: 0, width: width, height: height / 2)
        case .bottom:
            return CGRect(x: 0, y: height / 2, width: width, height: height / 2)
        }
    }

    /// Index passed to `addToSplit`. `paneCount` means after the last pane.
    static func insertionIndex(for zone: SplitDropZone, paneCount: Int) -> Int {
        switch zone {
        case .leading, .top:
            return 0
        case .trailing, .bottom:
            return max(paneCount, 0)
        }
    }

    /// `MYBROWSER_DEBUG_SPLIT_DROP=leading|trailing|top|bottom` freezes the overlay for a snapshot.
    static func debugDropZone() -> SplitDropZone? {
        switch ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_SPLIT_DROP"]?.lowercased() {
        case "leading", "left":
            return .leading
        case "trailing", "right":
            return .trailing
        case "top":
            return .top
        case "bottom":
            return .bottom
        default:
            return nil
        }
    }

    static func rect(span: SplitSpan, vertical: Bool, cross: CGFloat) -> CGRect {
        if vertical {
            return CGRect(x: 0, y: span.origin, width: cross, height: span.length)
        }
        return CGRect(x: span.origin, y: 0, width: span.length, height: cross)
    }

    /// `insertion` counts the dragged pane. `movePane` wants the index in the final order, which does not.
    static func finalIndex(current: Int?, insertion: Int) -> Int {
        guard let current else { return insertion }
        return current < insertion ? max(0, insertion - 1) : insertion
    }
}
