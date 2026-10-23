import Foundation
import Testing
@testable import myBrowser

struct PictureInPicturePolicyTests {
    private let tabA = UUID()
    private let tabB = UUID()

    @Test func leavingAPlayingTabEntersAndComingBackExits() {
        let (session, effects) = PictureInPicturePolicy.selection(
            autoEnabled: true,
            session: nil,
            from: tabA,
            fromCanEnter: true,
            to: tabB
        )
        #expect(session == PictureInPictureSession(tabID: tabA, origin: .leftTab))
        #expect(effects == [.enter(tabA, .leftTab)])

        let (back, backEffects) = PictureInPicturePolicy.selection(
            autoEnabled: true,
            session: session,
            from: tabB,
            fromCanEnter: false,
            to: tabA
        )
        #expect(back == nil)
        #expect(backEffects == [.exit(tabA)])
    }

    @Test func autoOffDoesNotEnterOnSelectionOrFocus() {
        let (session, effects) = PictureInPicturePolicy.selection(
            autoEnabled: false,
            session: nil,
            from: tabA,
            fromCanEnter: true,
            to: tabB
        )
        #expect(session == nil)
        #expect(effects.isEmpty)

        let (focused, focusEffects) = PictureInPicturePolicy.focus(
            autoEnabled: false,
            session: nil,
            windowFocused: false,
            selectedTab: tabA,
            selectedCanEnter: true
        )
        #expect(focused == nil)
        #expect(focusEffects.isEmpty)
    }

    @Test func losingTheWindowEntersAndRegainingItExitsOnlyThatSession() {
        let (session, effects) = PictureInPicturePolicy.focus(
            autoEnabled: true,
            session: nil,
            windowFocused: false,
            selectedTab: tabA,
            selectedCanEnter: true
        )
        #expect(session == PictureInPictureSession(tabID: tabA, origin: .leftWindow))
        #expect(effects == [.enter(tabA, .leftWindow)])

        let (back, backEffects) = PictureInPicturePolicy.focus(
            autoEnabled: true,
            session: session,
            windowFocused: true,
            selectedTab: tabA,
            selectedCanEnter: false
        )
        #expect(back == nil)
        #expect(backEffects == [.exit(tabA)])

        let manual = PictureInPictureSession(tabID: tabA, origin: .manual)
        let (still, stillEffects) = PictureInPicturePolicy.focus(
            autoEnabled: true,
            session: manual,
            windowFocused: true,
            selectedTab: tabA,
            selectedCanEnter: false
        )
        #expect(still == manual)
        #expect(stillEffects.isEmpty)
    }

    @Test func closingThePanelPausesAndDoesNotChangeTabs() {
        let session = PictureInPictureSession(tabID: tabA, origin: .leftTab)
        let (left, effects) = PictureInPicturePolicy.ended(session: session, tabID: tabA, dismissal: .stop)
        #expect(left == nil)
        #expect(effects == [.pause(tabA)])

        let (closed, closedEffects) = PictureInPicturePolicy.ended(session: session, tabID: tabA, dismissal: .requested)
        #expect(closed == nil)
        #expect(closedEffects.isEmpty)
    }

    @Test func returnToPageFocusesTheTab() {
        let session = PictureInPictureSession(tabID: tabA, origin: .leftWindow)
        let (still, reveal) = PictureInPicturePolicy.restore(session: session, tabID: tabA)
        #expect(still == session)
        #expect(reveal == [.focus(tabA)])

        let (left, effects) = PictureInPicturePolicy.ended(session: session, tabID: tabA, dismissal: .restore)
        #expect(left == nil)
        #expect(effects == [.focus(tabA)])
    }

    @Test func closingBlocksAutoEnterUntilTheVideoPausesAndPlaysAgain() {
        let earlier = Date(timeIntervalSinceReferenceDate: 0)
        var block: PictureInPictureAutoBlock? = PictureInPictureAutoBlock(
            tabID: tabA,
            sawIdle: false,
            holdUntil: earlier
        )

        var decision = PictureInPicturePolicy.autoEnter(
            block: block, tabID: tabA, canEnter: true, isActive: false, now: earlier
        )
        #expect(decision.allowed == false)
        #expect(decision.block?.sawIdle == false)
        block = decision.block

        decision = PictureInPicturePolicy.autoEnter(
            block: block, tabID: tabA, canEnter: false, isActive: true, now: earlier
        )
        #expect(decision.allowed == false)
        #expect(decision.block?.sawIdle == false)

        decision = PictureInPicturePolicy.autoEnter(
            block: block, tabID: tabA, canEnter: false, isActive: false, now: earlier
        )
        #expect(decision.allowed == false)
        #expect(decision.block?.sawIdle == true)
        block = decision.block

        decision = PictureInPicturePolicy.autoEnter(
            block: block, tabID: tabA, canEnter: true, isActive: false, now: earlier
        )
        #expect(decision.allowed == true)
        #expect(decision.block == nil)

        var held = PictureInPicturePolicy.userStopBlock(tabID: tabA, now: earlier)
        held.sawIdle = true
        let duringHold = PictureInPicturePolicy.autoEnter(
            block: held, tabID: tabA, canEnter: true, isActive: false, now: earlier.addingTimeInterval(1)
        )
        #expect(duringHold.allowed == false)
        #expect(duringHold.block == held)

        let other = PictureInPicturePolicy.userStopBlock(tabID: tabA, now: earlier)
        let unrelated = PictureInPicturePolicy.autoEnter(
            block: other, tabID: tabB, canEnter: true, isActive: false, now: earlier
        )
        #expect(unrelated.allowed == true)
        #expect(unrelated.block == other)
    }

    @Test func toggleEntersManuallyAndExitsWhenAlreadyActive() {
        let (session, effects) = PictureInPicturePolicy.toggle(session: nil, tabID: tabA, isActive: false)
        #expect(session == PictureInPictureSession(tabID: tabA, origin: .manual))
        #expect(effects == [.enter(tabA, .manual)])

        let (gone, exit) = PictureInPicturePolicy.toggle(session: session, tabID: tabA, isActive: true)
        #expect(gone == nil)
        #expect(exit == [.exit(tabA)])
    }

    @Test func sitesThatCannotEnterStayPut() {
        let (session, effects) = PictureInPicturePolicy.selection(
            autoEnabled: true,
            session: nil,
            from: tabA,
            fromCanEnter: false,
            to: tabB
        )
        #expect(session == nil)
        #expect(effects.isEmpty)
    }
}
