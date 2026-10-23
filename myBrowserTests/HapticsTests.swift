import CoreGraphics
import Foundation
import Testing
@testable import myBrowser

struct HapticsTests {
    @Test func gateFiresOncePerNewToken() {
        var gate = HapticGate<String>()
        #expect(gate.changed(to: "a") == "a")
        #expect(gate.changed(to: "a") == nil)
        #expect(gate.changed(to: "a") == nil)
        #expect(gate.changed(to: "b") == "b")
        #expect(gate.changed(to: nil) == nil)
        #expect(gate.token == nil)
        #expect(gate.changed(to: "b") == "b")
        gate.reset()
        #expect(gate.changed(to: "b") == "b")
    }

    @Test func navigationDistanceMatchesWebKit() {
        #expect(NavigationSwipeReading.thresholdFraction(width: 1000) == 0.1875)
        #expect(NavigationSwipeReading.thresholdFraction(width: 200) == 0.5)
        #expect(NavigationSwipeReading.thresholdFraction(width: 0) == 0.5)
    }

    @Test func navigationReadingUsesTheSwipeLayer() {
        let back = NavigationSwipeReading.read(
            NavigationSwipeSample(swipeRootTranslation: 812.5, liveTranslation: nil, width: 1000)
        )
        #expect(back == NavigationSwipeReading(progress: 0.1875, direction: .back, hasSwipeLayer: true))

        let rested = NavigationSwipeReading.read(
            NavigationSwipeSample(swipeRootTranslation: 1000, liveTranslation: 40, width: 1000)
        )
        #expect(rested.progress == 0)
        #expect(rested.direction == .back)

        let forward = NavigationSwipeReading.read(
            NavigationSwipeSample(swipeRootTranslation: 0, liveTranslation: 187.5, width: 1000)
        )
        #expect(forward == NavigationSwipeReading(progress: 0.1875, direction: .forward, hasSwipeLayer: true))

        let idle = NavigationSwipeReading.read(
            NavigationSwipeSample(swipeRootTranslation: nil, liveTranslation: 400, width: 1000)
        )
        #expect(idle.hasSwipeLayer == false)
        #expect(idle.progress == 0)
    }

    @Test func navigationDetentFiresOncePerCrossing() {
        var detent = NavigationSwipeDetent()
        let below = detent.update(progress: 0.1, direction: .back, width: 1000, canGoBack: true, canGoForward: true)
        let cross = detent.update(progress: 0.1875, direction: .back, width: 1000, canGoBack: true, canGoForward: true)
        let held = detent.update(progress: 0.4, direction: .back, width: 1000, canGoBack: true, canGoForward: true)
        let chatter = detent.update(progress: 0.16, direction: .back, width: 1000, canGoBack: true, canGoForward: true)
        let retreat = detent.update(progress: 0.05, direction: .back, width: 1000, canGoBack: true, canGoForward: true)
        let again = detent.update(progress: 0.2, direction: .back, width: 1000, canGoBack: true, canGoForward: true)
        let blocked = detent.update(progress: 0.9, direction: .back, width: 1000, canGoBack: false, canGoForward: true)
        let forward = detent.update(progress: 0.9, direction: .forward, width: 1000, canGoBack: true, canGoForward: true)
        let still = detent.update(progress: 0.95, direction: .forward, width: 1000, canGoBack: true, canGoForward: true)
        #expect(below == false)
        #expect(cross)
        #expect(held == false)
        #expect(chatter == false)
        #expect(retreat == false)
        #expect(again)
        #expect(blocked == false)
        #expect(forward)
        #expect(still == false)
    }

    @Test func spaceDetentMatchesTheCommitLine() {
        #expect(SpaceSwipeTracker.armedDetent(offset: 0, width: 200, canGoPrevious: true, canGoNext: true) == .none)
        #expect(SpaceSwipeTracker.armedDetent(offset: 59, width: 200, canGoPrevious: true, canGoNext: true) == .none)
        #expect(SpaceSwipeTracker.armedDetent(offset: 60, width: 200, canGoPrevious: true, canGoNext: true) == .selectPrevious)
        #expect(SpaceSwipeTracker.armedDetent(offset: -60, width: 200, canGoPrevious: true, canGoNext: true) == .selectNext)
        #expect(SpaceSwipeTracker.armedDetent(offset: 80, width: 200, canGoPrevious: false, canGoNext: true) == .none)
        #expect(SpaceSwipeTracker.armedDetent(offset: -80, width: 200, canGoPrevious: true, canGoNext: false) == .none)
        #expect(SpaceSwipeTracker.armedDetent(offset: 40, width: 0, canGoPrevious: true, canGoNext: true) == .none)
    }

    @Test func dragHapticsFireOncePerSlotAndPinCrossing() {
        var drag = SidebarDragHaptics()
        let space = UUID()
        let folder = UUID()
        let first = insert(space: space, section: .tabs, position: .after(UUID()))
        let sameGap = insert(space: space, section: .tabs, position: first.position, token: UUID())
        let pinned = insert(space: space, section: .pinned, position: .start)
        let pinnedAgain = insert(space: space, section: .pinned, position: .after(UUID()))
        let icon = UUID()

        #expect(drag.note(.insert(first)) == .dropSlot)
        #expect(drag.note(.insert(sameGap)) == nil)
        #expect(drag.note(.intoFolder(folder)) == nil)
        #expect(drag.note(.insert(sameGap)) == nil)
        #expect(drag.note(.insert(pinned)) == .pinChange)
        #expect(drag.note(.insert(pinnedAgain)) == .dropSlot)
        #expect(drag.note(.insert(first)) == .pinChange)
        #expect(drag.note(.ontoSpace(icon)) == .spaceTarget)
        #expect(drag.note(.ontoSpace(icon)) == nil)
        #expect(drag.note(.intoSplit(folder)) == .dropSlot)
        #expect(drag.note(.intoSplit(folder)) == nil)
        #expect(drag.note(nil) == nil)
        drag.reset()
        #expect(drag.note(.ontoSpace(icon)) == .spaceTarget)
    }

    private func insert(
        space: UUID,
        section: SidebarItem.Section,
        position: SidebarDropPosition,
        token: UUID = UUID()
    ) -> SidebarInsertion {
        SidebarInsertion(
            spaceID: space,
            section: section,
            parentID: nil,
            position: position,
            depth: 0,
            indicatorToken: token,
            lineEdge: .bottom
        )
    }
}
