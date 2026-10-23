import AppKit
import SwiftUI
import Testing
@testable import myBrowser

/// Clicks the corners and the empty parts of a sidebar row. The hover pill is the hit target.
@MainActor
struct SidebarHitTargetTests {
    @Test func tabRowCornersPaddingGapAndTrailingSpaceSelect() throws {
        let harness = try Harness()
        let tab = harness.site("One", section: .tabs)
        let host = harness.host(SidebarRow(item: tab, onRename: {}), width: 240, height: 32)

        for point in [
            CGPoint(x: 1, y: 1),
            CGPoint(x: 239, y: 1),
            CGPoint(x: 1, y: 31),
            CGPoint(x: 239, y: 31),
            CGPoint(x: 3, y: 16),
            CGPoint(x: 27, y: 16),
            CGPoint(x: 200, y: 16),
        ] {
            harness.clearSelection()
            harness.click(host, x: point.x, yFromTop: point.y)
            #expect(harness.model.selectedItemID == tab.id, "missed \(point)")
        }
    }

    @Test func pinnedRowEdgesSelect() throws {
        let harness = try Harness()
        let pin = harness.site("Pinned", section: .pinned)
        let host = harness.host(SidebarRow(item: pin, onRename: {}), width: 240, height: 32)

        for point in [
            CGPoint(x: 1, y: 1),
            CGPoint(x: 27, y: 2),
            CGPoint(x: 239, y: 1),
            CGPoint(x: 239, y: 31),
            CGPoint(x: 180, y: 30),
        ] {
            harness.clearSelection()
            harness.click(host, x: point.x, yFromTop: point.y)
            #expect(harness.model.selectedItemID == pin.id, "missed \(point)")
        }
    }

    @Test func stackedRowsDoNotStealEachOthersCorners() throws {
        let harness = try Harness()
        let top = harness.site("Top", section: .tabs)
        let bottom = harness.site("Bottom", section: .tabs)
        let host = harness.host(
            VStack(spacing: 1) {
                SidebarRow(item: top, onRename: {})
                SidebarRow(item: bottom, onRename: {})
            },
            width: 240,
            height: 65
        )

        harness.click(host, x: 239, yFromTop: 1)
        #expect(harness.model.selectedItemID == top.id)
        harness.click(host, x: 1, yFromTop: 31)
        #expect(harness.model.selectedItemID == top.id)

        harness.click(host, x: 1, yFromTop: 34)
        #expect(harness.model.selectedItemID == bottom.id)
        harness.click(host, x: 239, yFromTop: 64)
        #expect(harness.model.selectedItemID == bottom.id)
    }

    @Test func folderCornerToggles() throws {
        let harness = try Harness()
        let folder = harness.folder("Projects")
        let host = harness.host(
            PinnedTree(spaceID: harness.spaceID, onRename: { _ in }, onNewFolder: { _ in }),
            width: 240,
            height: 32
        )
        #expect(harness.library.item(folder.id)?.isExpanded == true)
        harness.click(host, x: 238, yFromTop: 2)
        #expect(harness.library.item(folder.id)?.isExpanded == false)
        harness.click(host, x: 2, yFromTop: 30)
        #expect(harness.library.item(folder.id)?.isExpanded == true)
    }

    @Test func favoriteTileCornersSelect() throws {
        let harness = try Harness()
        let tile = harness.site("GitHub", section: .favorites)
        let host = harness.host(
            FavoritesGrid(spaceID: harness.spaceID, onRename: { _ in }, onNewFolder: {}),
            width: 160,
            height: 44
        )
        for point in [
            CGPoint(x: 2, y: 5),
            CGPoint(x: 158, y: 5),
            CGPoint(x: 2, y: 41),
            CGPoint(x: 158, y: 41),
        ] {
            harness.clearSelection()
            harness.click(host, x: point.x, yFromTop: point.y)
            #expect(harness.model.selectedItemID == tile.id, "missed \(point)")
        }
    }

    @Test func newTabCornerOpensTheCommandBar() throws {
        let harness = try Harness()
        let host = harness.host(
            TabList(spaceID: harness.spaceID, onRename: { _ in }, onNewFolder: {}),
            width: 240,
            height: 32
        )
        harness.click(host, x: 236, yFromTop: 2)
        #expect(harness.model.commandBarMode == .newTab)
    }

    @Test func splitSegmentCornersFocusThePane() throws {
        let harness = try Harness()
        let left = harness.site("Left", section: .tabs)
        let right = harness.site("Right", section: .tabs)
        let split = try #require(harness.library.createSplit(tabIDs: [left.id, right.id]))
        let host = harness.host(SidebarRow(item: split, onRename: {}), width: 240, height: 32)

        harness.clearSelection()
        harness.click(host, x: 2, yFromTop: 2)
        #expect(harness.model.selectedItemID == split.id)
        #expect(harness.model.resolvedFocus(in: split.id) == left.id)

        harness.click(host, x: 238, yFromTop: 30)
        #expect(harness.model.selectedItemID == split.id)
        #expect(harness.model.resolvedFocus(in: split.id) == right.id)
    }
}

@MainActor
private struct Harness {
    let model: BrowserModel
    let library: LibraryStore
    let spaceID: UUID
    private let interaction = SidebarInteraction()

    init() throws {
        library = LibraryStore(directory: nil)
        let session = SessionStore(directory: nil)
        model = BrowserModel(library: library, session: session)
        spaceID = try #require(model.selectedSpace?.id)
        interaction.model = model
    }

    func site(_ title: String, section: SidebarItem.Section) -> SidebarItem {
        library.addItem(
            spaceID: spaceID,
            section: section,
            kind: .site,
            title: title,
            url: URL(string: "https://\(title.lowercased()).example"),
            at: .end
        )
    }

    func folder(_ title: String) -> SidebarItem {
        library.addItem(spaceID: spaceID, section: .pinned, kind: .folder, title: title, at: .end)
    }

    func clearSelection() {
        model.session.selectedItemBySpace[spaceID] = nil
    }

    func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<AnyView> {
        let root = AnyView(
            view
                .environment(model)
                .environment(interaction)
                .frame(width: width, height: height)
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        return host
    }

    func click(_ host: NSView, x: CGFloat, yFromTop: CGFloat) {
        let localY = host.isFlipped ? yFromTop : host.bounds.height - yFromTop
        let windowPoint = host.convert(NSPoint(x: x, y: localY), to: nil)
        guard let window = host.window else {
            Issue.record("row host has no window")
            return
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            Issue.record("could not build a click")
            return
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }
}
