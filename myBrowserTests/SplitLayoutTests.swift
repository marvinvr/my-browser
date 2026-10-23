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

    @Test func aNewSplitUsesWholeHalvesAndEdgeBands() {
        let size = CGSize(width: 800, height: 600)
        let band = size.height * 0.20

        #expect(SplitGeometry.dropZone(at: CGPoint(x: 100, y: 300), size: size, mode: .choose) == .leading)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 500, y: 300), size: size, mode: .choose) == .trailing)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 10, y: band), size: size, mode: .choose) == .top)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 790, y: band + 1), size: size, mode: .choose) == .trailing)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 10, y: size.height - band), size: size, mode: .choose) == .bottom)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 399, y: 300), size: size, mode: .choose) == .leading)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 400, y: 300), size: size, mode: .choose) == .trailing)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: -1, y: 300), size: size, mode: .choose) == nil)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 10, y: 10), size: CGSize(width: 0, height: 0), mode: .choose) == nil)
    }

    @Test func anOpenSplitUsesTheWholeCardAlongItsAxis() {
        let size = CGSize(width: 800, height: 600)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 10, y: 10), size: size, mode: .horizontal) == .leading)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 790, y: 590), size: size, mode: .horizontal) == .trailing)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 10, y: 10), size: size, mode: .vertical) == .top)
        #expect(SplitGeometry.dropZone(at: CGPoint(x: 790, y: 400), size: size, mode: .vertical) == .bottom)
    }

    @Test func previewCoversTheChosenHalf() {
        let size = CGSize(width: 800, height: 600)
        #expect(SplitGeometry.previewRect(for: .leading, size: size) == CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(SplitGeometry.previewRect(for: .trailing, size: size) == CGRect(x: 400, y: 0, width: 400, height: 600))
        #expect(SplitGeometry.previewRect(for: .top, size: size) == CGRect(x: 0, y: 0, width: 800, height: 300))
        #expect(SplitGeometry.previewRect(for: .bottom, size: size) == CGRect(x: 0, y: 300, width: 800, height: 300))
        #expect(SplitGeometry.insertionIndex(for: .leading, paneCount: 3) == 0)
        #expect(SplitGeometry.insertionIndex(for: .top, paneCount: 3) == 0)
        #expect(SplitGeometry.insertionIndex(for: .trailing, paneCount: 3) == 3)
        #expect(SplitGeometry.insertionIndex(for: .bottom, paneCount: 2) == 2)
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
