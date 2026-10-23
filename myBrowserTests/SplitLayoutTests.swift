import CoreGraphics
import Testing
@testable import myBrowser

@MainActor
struct SplitLayoutTests {
    @Test func missingShareMakesEqualPanes() {
        let thirds = SplitGeometry.shares(from: [nil, nil, nil])
        #expect(thirds.count == 3)
        #expect(near(thirds[0], 1.0 / 3))
        #expect(near(thirds[1], 1.0 / 3))
        let halves = SplitGeometry.shares(from: [Double?(0.25), nil])
        #expect(near(halves[0], 0.5))
        #expect(near(halves[1], 0.5))
    }

    @Test func sharesNormalizeToOne() {
        let shares = SplitGeometry.shares(from: [2, 1])
        #expect(near(shares[0], 2.0 / 3))
        #expect(near(shares[1], 1.0 / 3))
    }

    @Test func dragStopsAtMinimum() {
        let next = SplitGeometry.sharesByDragging(
            start: [0.5, 0.5],
            divider: 0,
            translation: 400,
            available: 1000,
            minimum: 240
        )
        #expect(near(next[0], 0.76))
        #expect(near(next[1], 0.24))

        let back = SplitGeometry.sharesByDragging(
            start: [0.5, 0.5],
            divider: 0,
            translation: -1000,
            available: 1000,
            minimum: 240
        )
        #expect(near(back[0], 0.24))
        #expect(near(back[1], 0.76))
    }

    @Test func narrowCardSharesTheSpace() {
        let lengths = SplitGeometry.lengths(shares: [0.5, 0.5], available: 400, minimum: 240)
        #expect(near(lengths[0], 200, tolerance: 0.5))
        #expect(near(lengths[1], 200, tolerance: 0.5))
    }

    @Test func smallShareClampsAndGivesTheRestAway() {
        let lengths = SplitGeometry.lengths(shares: [0.9, 0.1], available: 1000, minimum: 240)
        #expect(near(lengths[0], 760, tolerance: 0.5))
        #expect(near(lengths[1], 240, tolerance: 0.5))
    }

    @Test func dropZonesAreEdgesAndGaps() {
        let single = [SplitSpan(origin: 0, length: 800)]
        #expect(SplitGeometry.dropIndex(at: 10, spans: single, edgeFraction: 0.3, dividerReach: 28) == 0)
        #expect(SplitGeometry.dropIndex(at: 400, spans: single, edgeFraction: 0.3, dividerReach: 28) == nil)
        #expect(SplitGeometry.dropIndex(at: 700, spans: single, edgeFraction: 0.3, dividerReach: 28) == 1)

        let pair = [SplitSpan(origin: 0, length: 400), SplitSpan(origin: 406, length: 400)]
        #expect(SplitGeometry.dropIndex(at: 20, spans: pair, edgeFraction: 0.3, dividerReach: 28) == 0)
        #expect(SplitGeometry.dropIndex(at: 200, spans: pair, edgeFraction: 0.3, dividerReach: 28) == nil)
        #expect(SplitGeometry.dropIndex(at: 403, spans: pair, edgeFraction: 0.3, dividerReach: 28) == 1)
        #expect(SplitGeometry.dropIndex(at: 760, spans: pair, edgeFraction: 0.3, dividerReach: 28) == 2)
    }

    @Test func previewIsHalfAPane() {
        let spans = [SplitSpan(origin: 0, length: 400), SplitSpan(origin: 406, length: 400)]
        let leading = SplitGeometry.preview(for: 0, spans: spans)
        #expect(leading?.origin == 0)
        #expect(leading?.length == 200)
        let between = SplitGeometry.preview(for: 1, spans: spans)
        #expect(between?.length == 200)
        let trailing = SplitGeometry.preview(for: 2, spans: spans)
        #expect(trailing?.origin == 606)
        #expect(trailing?.length == 200)
    }

    @Test func movingForwardUsesTheFinalIndex() {
        #expect(SplitGeometry.finalIndex(current: 0, insertion: 2) == 1)
        #expect(SplitGeometry.finalIndex(current: 0, insertion: 3) == 2)
        #expect(SplitGeometry.finalIndex(current: 2, insertion: 0) == 0)
        #expect(SplitGeometry.finalIndex(current: 1, insertion: 2) == 1)
        #expect(SplitGeometry.finalIndex(current: nil, insertion: 1) == 1)
    }

    private func near(_ value: Double, _ expected: Double, tolerance: Double = 0.0001) -> Bool {
        abs(value - expected) < tolerance
    }

    private func near(_ value: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.0001) -> Bool {
        abs(value - expected) < tolerance
    }
}
