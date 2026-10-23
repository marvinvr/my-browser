import Testing
@testable import myBrowser

struct DebugNoteRoutingTests {
    @Test func privateChannelIgnoresUnscopedNotes() {
        let mine = ["ch.marvinvr.mybrowser.debug.dndqa"]
        #expect(DebugNoteRouting.accepts(noteChannel: nil, processChannels: mine) == false)
        #expect(DebugNoteRouting.accepts(noteChannel: "", processChannels: mine) == false)
        #expect(DebugNoteRouting.accepts(noteChannel: "ch.marvinvr.mybrowser.debug.other", processChannels: mine) == false)
        #expect(DebugNoteRouting.accepts(noteChannel: "ch.marvinvr.mybrowser.debug.dndqa", processChannels: mine))
    }

    @Test func processWithoutAChannelOnlyAcceptsUnscopedNotes() {
        #expect(DebugNoteRouting.accepts(noteChannel: nil, processChannels: []))
        #expect(DebugNoteRouting.accepts(noteChannel: "  ", processChannels: [" "]))
        #expect(DebugNoteRouting.accepts(noteChannel: "ch.marvinvr.mybrowser.debug.dndqa", processChannels: []) == false)
    }
}
