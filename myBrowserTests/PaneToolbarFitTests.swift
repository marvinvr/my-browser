import Testing
@testable import myBrowser

struct PaneToolbarFitTests {
    @Test func aWidePaneKeepsEveryControl() {
        let fit = PaneToolbarFit.resolve(width: 400, traffic: 0, windowControlsWidth: 0)
        #expect(fit == PaneToolbarFit())
        #expect(fit.overflow == false)
    }

    @Test func theMinimumPaneKeepsSeparateSwapAndClose() {
        let fit = PaneToolbarFit.resolve(width: 240, traffic: 0, windowControlsWidth: 0)
        #expect(fit.forward && fit.separate && fit.swap && fit.windowControls)
        #expect(fit.copyLink == false)
        #expect(fit.overflow == false)
    }

    @Test func threePanesAtTheDefaultWindowKeepTheCopyButton() {
        let fit = PaneToolbarFit.resolve(width: 337, traffic: 0, windowControlsWidth: 0)
        #expect(fit == PaneToolbarFit())
        let comfort = PaneToolbarFit.used(fit, traffic: 0, window: 0, address: PaneToolbarMetrics.addressComfort)
        #expect(comfort <= 337)
    }

    @Test func fourPanesDropTheCopyButtonAndKeepThePaneActions() {
        let fit = PaneToolbarFit.resolve(width: 251, traffic: 0, windowControlsWidth: 0)
        #expect(fit.forward && fit.separate && fit.swap)
        #expect(fit.copyLink == false)
        #expect(fit.overflow == false)
    }

    @Test func aTightPaneMovesSwapAndSeparateIntoTheMenu() {
        let fit = PaneToolbarFit.resolve(width: 200, traffic: 0, windowControlsWidth: 0)
        #expect(fit.overflow)
        #expect(fit.swap == false)
        #expect(fit.separate == false)
        #expect(fit.forward)
        #expect(fit.copyLink == false)
    }

    @Test func windowControlsLeaveBeforeForward() {
        let fit = PaneToolbarFit.resolve(width: 250, traffic: 0, windowControlsWidth: 80)
        #expect(fit.windowControls == false)
        #expect(fit.forward)
        #expect(fit.overflow)
    }

    @Test func trafficClearanceDropsTheExtrasAndKeepsBackReloadAndClose() {
        let fit = PaneToolbarFit.resolve(width: 250, traffic: 74, windowControlsWidth: 0)
        #expect(fit.swap == false)
        #expect(fit.separate == false)
        #expect(fit.windowControls)
    }
}
