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

    @Test func returnFromThePanelFocusesTheTabUnlessWeClosedIt() {
        let session = PictureInPictureSession(tabID: tabA, origin: .leftTab)
        let (left, effects) = PictureInPicturePolicy.ended(session: session, tabID: tabA, requestedByUs: false)
        #expect(left == nil)
        #expect(effects == [.focus(tabA)])

        let (closed, closedEffects) = PictureInPicturePolicy.ended(session: session, tabID: tabA, requestedByUs: true)
        #expect(closed == nil)
        #expect(closedEffects.isEmpty)
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
