import AppKit
import Foundation
import SwiftUI
import Testing
@testable import myBrowser

struct SpaceSwipeTrackerTests {
    private func tracker(
        width: CGFloat = 200,
        previous: Bool = true,
        next: Bool = true
    ) -> SpaceSwipeTracker {
        var tracker = SpaceSwipeTracker()
        tracker.width = width
        tracker.canGoPrevious = previous
        tracker.canGoNext = next
        return tracker
    }

    private func feed(
        _ tracker: inout SpaceSwipeTracker,
        _ phase: SpaceSwipePhase,
        x: CGFloat = 0,
        y: CGFloat = 0,
        time: TimeInterval,
        inside: Bool = true
    ) -> SpaceSwipeUpdate {
        tracker.handle(SpaceSwipeSample(phase: phase, deltaX: x, deltaY: y, time: time, inside: inside))
    }

    /// Release speed is asserted on its own. These checks only care where the column is sent.
    private func expectSettle(
        _ update: SpaceSwipeUpdate,
        offset: CGFloat,
        action: SpaceSwipeAction,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .settle(let gotOffset, let gotAction, _) = update else {
            Issue.record(
                "expected settle(offset: \(offset), action: \(action)), got \(update)",
                sourceLocation: sourceLocation
            )
            return
        }
        #expect(gotOffset == offset, sourceLocation: sourceLocation)
        #expect(gotAction == action, sourceLocation: sourceLocation)
    }

    @Test func phaseBitsMatchAppKit() {
        #expect(SpaceSwipePhase.from(phaseRaw: NSEvent.Phase.began.rawValue, momentumRaw: 0) == .began)
        #expect(SpaceSwipePhase.from(phaseRaw: NSEvent.Phase.mayBegin.rawValue, momentumRaw: 0) == .began)
        #expect(SpaceSwipePhase.from(phaseRaw: NSEvent.Phase.changed.rawValue, momentumRaw: 0) == .changed)
        #expect(SpaceSwipePhase.from(phaseRaw: NSEvent.Phase.stationary.rawValue, momentumRaw: 0) == .changed)
        #expect(SpaceSwipePhase.from(phaseRaw: NSEvent.Phase.ended.rawValue, momentumRaw: 0) == .ended)
        #expect(SpaceSwipePhase.from(phaseRaw: NSEvent.Phase.cancelled.rawValue, momentumRaw: 0) == .cancelled)
        #expect(SpaceSwipePhase.from(phaseRaw: 0, momentumRaw: NSEvent.Phase.changed.rawValue) == .momentum(ended: false))
        #expect(SpaceSwipePhase.from(phaseRaw: 0, momentumRaw: NSEvent.Phase.ended.rawValue) == .momentum(ended: true))
        #expect(SpaceSwipePhase.from(phaseRaw: 0, momentumRaw: NSEvent.Phase.cancelled.rawValue) == .cancelled)
        #expect(SpaceSwipePhase.from(phaseRaw: 0, momentumRaw: 0) == .other)
    }

    @Test func mouseWheelNeverClaims() {
        var swipe = tracker()
        let update = feed(&swipe, .other, x: 80, y: 0, time: 0)
        #expect(update == .passthrough)
        #expect(swipe.offset == 0)
    }

    @Test func verticalGestureIsLeftToTheList() {
        var swipe = tracker()
        #expect(feed(&swipe, .began, time: 0) == .passthrough)
        #expect(feed(&swipe, .changed, x: 2, y: 8, time: 0.02) == .passthrough)
        #expect(feed(&swipe, .changed, x: 30, y: 4, time: 0.04) == .passthrough)
        #expect(feed(&swipe, .ended, time: 0.05) == .passthrough)
        #expect(feed(&swipe, .momentum(ended: false), x: 0, y: 12, time: 0.08) == .passthrough)
        #expect(feed(&swipe, .momentum(ended: true), time: 0.2) == .passthrough)
        #expect(swipe.offset == 0)
    }

    @Test func dominanceIsStrictAndDecidedAtTheStart() {
        var diagonal = tracker()
        // |dx| == |dy| * 1.5 is not enough.
        #expect(feed(&diagonal, .changed, x: 15, y: 10, time: 0) == .passthrough)
        #expect(diagonal.offset == 0)

        var horizontal = tracker()
        let claimed = feed(&horizontal, .changed, x: 16, y: 10, time: 0)
        #expect(claimed == .tracking(offset: 16))
    }

    @Test func slopIncludesTheOpeningSamples() {
        var swipe = tracker()
        #expect(feed(&swipe, .began, x: 1, y: 0, time: 0) == .passthrough)
        let claimed = feed(&swipe, .changed, x: 4, y: 0, time: 0.01)
        #expect(claimed == .tracking(offset: 5))
    }

    @Test func tracksTheFingerOneToOne() {
        var swipe = tracker()
        #expect(feed(&swipe, .changed, x: 40, y: 0, time: 0) == .tracking(offset: 40))
        #expect(feed(&swipe, .changed, x: -15, y: 0, time: 0.02) == .tracking(offset: 25))
        #expect(swipe.offset == 25)
    }

    @Test func releaseUnderThirtyPercentSpringsBack() {
        var swipe = tracker()
        _ = feed(&swipe, .changed, x: 59, y: 0, time: 0)
        let update = feed(&swipe, .ended, time: 0.05)
        expectSettle(update, offset: 0, action: .none)
    }

    @Test func releasePastThirtyPercentCommits() {
        var next = tracker()
        _ = feed(&next, .changed, x: -60, y: 0, time: 0)
        expectSettle(feed(&next, .ended, time: 0.05), offset: -200, action: .selectNext)

        var previous = tracker()
        _ = feed(&previous, .changed, x: 60, y: 0, time: 0)
        expectSettle(feed(&previous, .ended, time: 0.05), offset: 200, action: .selectPrevious)
    }

    @Test func flickBelowTheDistanceCommits() {
        var swipe = tracker()
        _ = feed(&swipe, .began, time: 0)
        _ = feed(&swipe, .changed, x: -15, y: 0, time: 0.01)
        _ = feed(&swipe, .changed, x: -20, y: 0, time: 0.02)
        let update = feed(&swipe, .ended, x: 0, y: 0, time: 0.03)
        expectSettle(update, offset: -200, action: .selectNext)
        #expect(abs(35) < 200 * 0.30)
    }

    @Test func flickBackCancelsADragPastTheThreshold() {
        var swipe = tracker()
        _ = feed(&swipe, .changed, x: -100, y: 0, time: 0)
        _ = feed(&swipe, .changed, x: 8, y: 0, time: 0.20)
        _ = feed(&swipe, .changed, x: 8, y: 0, time: 0.205)
        let update = feed(&swipe, .ended, x: 4, y: 0, time: 0.210)
        expectSettle(update, offset: 0, action: .none)
    }

    @Test func rubberBandsOnTheFirstAndLastSpace() {
        let resisted = SpaceSwipeTracker.rubberBand(100, dimension: 200)
        #expect(resisted > 0)
        #expect(resisted < 40)
        #expect(abs(resisted - 19.411764705882353) < 0.001)

        var first = tracker(previous: false, next: true)
        let right = feed(&first, .changed, x: 100, y: 0, time: 0)
        #expect(right == .tracking(offset: resisted))
        expectSettle(feed(&first, .ended, time: 0.1), offset: 0, action: .none)

        var last = tracker(previous: true, next: false)
        let left = feed(&last, .changed, x: -100, y: 0, time: 0)
        #expect(left == .tracking(offset: -resisted))
        expectSettle(feed(&last, .ended, time: 0.1), offset: 0, action: .none)
    }

    @Test func aLongDragPastOneColumnResists() {
        var swipe = tracker()
        let update = feed(&swipe, .changed, x: 300, y: 0, time: 0)
        let extra = SpaceSwipeTracker.rubberBand(100, dimension: 200)
        #expect(update == .tracking(offset: 200 + extra))
    }

    @Test func momentumAfterCommitDoesNotMoveTheOffset() {
        var swipe = tracker()
        _ = feed(&swipe, .changed, x: -80, y: 0, time: 0)
        expectSettle(feed(&swipe, .ended, time: 0.04), offset: -200, action: .selectNext)
        #expect(feed(&swipe, .momentum(ended: false), x: 400, y: 0, time: 0.06) == .consume)
        #expect(feed(&swipe, .momentum(ended: false), x: -50, y: 20, time: 0.08) == .consume)
        #expect(swipe.offset == -200)
        swipe.noteSettleFinished()
        #expect(feed(&swipe, .momentum(ended: true), time: 0.2) == .consume)
        // The tail is dropped. Finishing the coast resets; it does not add the momentum delta.
        #expect(swipe.offset == 0)

        let vertical = feed(&swipe, .changed, x: 1, y: 12, time: 0.4)
        #expect(vertical == .passthrough)
    }

    @Test func cancelSpringsBack() {
        var swipe = tracker()
        _ = feed(&swipe, .changed, x: 80, y: 0, time: 0)
        expectSettle(feed(&swipe, .cancelled, time: 0.02), offset: 0, action: .none)
    }

    @Test func eventsOutsideDoNotStartAGesture() {
        var swipe = tracker()
        #expect(feed(&swipe, .changed, x: 40, y: 0, time: 0, inside: false) == .passthrough)
        #expect(swipe.offset == 0)

        _ = feed(&swipe, .changed, x: 30, y: 0, time: 0.1)
        let outside = feed(&swipe, .changed, x: 12, y: 0, time: 0.12, inside: false)
        #expect(outside == .tracking(offset: 42))
    }

    @Test func newTouchOutsideWhileTrackingSettles() {
        var short = tracker(width: 200)
        #expect(feed(&short, .changed, x: 40, y: 0, time: 0) == .tracking(offset: 40))
        expectSettle(feed(&short, .began, time: 1, inside: false), offset: 0, action: .none)

        var far = tracker(width: 200)
        #expect(feed(&far, .changed, x: 80, y: 0, time: 0) == .tracking(offset: 80))
        expectSettle(feed(&far, .began, time: 1, inside: false), offset: 200, action: .selectPrevious)
    }

    @Test func interruptWhileTrackingSettles() {
        var short = tracker(width: 200)
        _ = feed(&short, .changed, x: 40, y: 0, time: 0)
        expectSettle(short.interrupt(), offset: 0, action: .none)

        var far = tracker(width: 200)
        _ = feed(&far, .changed, x: 80, y: 0, time: 0)
        expectSettle(far.interrupt(), offset: 200, action: .selectPrevious)

        var idle = tracker()
        #expect(idle.interrupt() == .passthrough)
    }

    @Test func releaseCarriesTheFingerVelocity() {
        var swipe = tracker()
        _ = feed(&swipe, .changed, x: -20, y: 0, time: 0)
        _ = feed(&swipe, .changed, x: -20, y: 0, time: 0.02)
        let update = feed(&swipe, .ended, x: 0, y: 0, time: 0.04)
        guard case .settle(_, _, let velocity) = update else {
            Issue.record("expected a settle with the finger speed")
            return
        }
        #expect(abs(velocity - (-2000)) < 1)
    }

    @Test func settleSpringIsCriticallyDampedAndShort() {
        let spring = SpaceSwipeMotion.spring
        #expect(spring.bounce == 0)
        #expect(abs(spring.duration - 0.22) < 0.0001)
        #expect(abs(spring.dampingRatio - 1) < 0.001)
        let arrived = spring.value(target: 1.0, initialVelocity: 0.0, time: 0.22)
        #expect(arrived > 0.98)
        #expect(arrived <= 1)
        let coasting = spring.value(target: 1.0, initialVelocity: 4.0, time: 0.08)
        let resting = spring.value(target: 1.0, initialVelocity: 0.0, time: 0.08)
        #expect(coasting > resting)
        #expect(coasting <= 1)

        #expect(abs(SpaceSwipeMotion.carried(from: -80, to: -240, velocity: -1400) - (-1400)) < 0.01)
        #expect(abs(SpaceSwipeMotion.carried(from: -80, to: -240, velocity: -5000) - (-2000)) < 0.01)
        #expect(SpaceSwipeMotion.carried(from: -280, to: -240, velocity: -1400) == 0)
        #expect(SpaceSwipeMotion.carried(from: -80, to: -240, velocity: 400) == 0)
        #expect(abs(SpaceSwipeMotion.carried(from: 40, to: 0, velocity: -900) - (-500)) < 0.01)
    }

    @Test func prewarmNeighbourLoadsWithoutSelectingIt() throws {
        let library = LibraryStore(directory: nil)
        let session = SessionStore(directory: nil)
        let model = BrowserModel(library: library, session: session)
        let first = try #require(model.selectedSpace?.id)
        let second = model.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)
        model.selectSpace(first)
        let item = library.addItem(
            spaceID: second.id,
            section: .tabs,
            kind: .site,
            title: "Beta",
            url: URL(string: "https://beta.example"),
            at: .end
        )
        session.selectedItemBySpace[second.id] = item.id

        model.prewarmNeighbourSpaces()

        #expect(model.selectedSpaceID == first)
        #expect(model.tabs[item.id]?.isLoaded == true)
        #expect(model.selectedTab?.id != item.id)
    }

    @Test func nextAndPreviousKeepTheirDirectionAcrossAWrap() throws {
        let library = LibraryStore(directory: nil)
        let session = SessionStore(directory: nil)
        let model = BrowserModel(library: library, session: session)
        let first = try #require(model.selectedSpace?.id)

        let second = model.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)
        #expect(model.selectedSpaceID == second.id)
        #expect(model.lastSpaceSwitchDirection == .next)

        model.selectNextSpace()
        #expect(model.selectedSpaceID == first)
        #expect(model.lastSpaceSwitchDirection == .next)

        model.selectPreviousSpace()
        #expect(model.selectedSpaceID == second.id)
        #expect(model.lastSpaceSwitchDirection == .previous)

        model.selectSpace(first)
        #expect(model.lastSpaceSwitchDirection == .previous)
    }
}
