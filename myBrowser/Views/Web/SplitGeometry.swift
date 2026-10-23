import CoreGraphics

/// Layout numbers for a split in the content card.
enum SplitMetrics {
    static let gap: CGFloat = 6
    static let minPane: CGFloat = 240
    static let cornerRadius: CGFloat = 8
    /// Drag target centered on the gap. Wider than the gap so the pointer can grab it.
    static let dividerHit: CGFloat = 10
    /// Outer fraction of an edge pane that accepts a new pane.
    static let edgeFraction: CGFloat = 0.30
    /// How far from a gap the pointer still counts as "between panes".
    static let dividerReach: CGFloat = 28
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

    /// Insertion index for a drop, or nil when the point is in the middle of a pane.
    /// `spans.count` means after the last pane.
    static func dropIndex(
        at point: CGFloat,
        spans: [SplitSpan],
        edgeFraction: CGFloat,
        dividerReach: CGFloat
    ) -> Int? {
        guard let first = spans.first, let last = spans.last, first.length > 1 else { return nil }
        if point <= first.origin + first.length * edgeFraction {
            return 0
        }
        if point >= last.origin + last.length * (1 - edgeFraction) {
            return spans.count
        }
        guard spans.count >= 2 else { return nil }
        for index in 0..<(spans.count - 1) {
            let end = spans[index].origin + spans[index].length
            let next = spans[index + 1].origin
            let mid = (end + next) / 2
            let reach = max(dividerReach, (next - end) / 2 + 4)
            if abs(point - mid) <= reach {
                return index + 1
            }
        }
        return nil
    }

    /// Half of the neighbouring pane, where the dropped page will sit.
    static func preview(for index: Int, spans: [SplitSpan]) -> SplitSpan? {
        guard let first = spans.first, let last = spans.last else { return nil }
        if index <= 0 {
            return SplitSpan(origin: first.origin, length: first.length / 2)
        }
        if index >= spans.count {
            let length = last.length / 2
            return SplitSpan(origin: last.origin + last.length - length, length: length)
        }
        let previous = spans[index - 1]
        let next = spans[index]
        let length = min(previous.length, next.length) / 2
        let boundary = (previous.origin + previous.length + next.origin) / 2
        return SplitSpan(origin: boundary - length / 2, length: length)
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
