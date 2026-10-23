import CoreGraphics
import Foundation
import Testing
@testable import myBrowser

@MainActor
struct SidebarDropGeometryTests {
    private func row(_ id: UUID, depth: Int, parentID: UUID?, folder: Bool = false, expanded: Bool = false) -> SidebarDropRow {
        SidebarDropRow(id: id, depth: depth, parentID: parentID, isFolder: folder, isExpanded: expanded)
    }

    @Test func gapAfterANestedChildCanUnindent() {
        let folder = UUID()
        let child = UUID()
        let sibling = UUID()
        let folderRow = row(folder, depth: 0, parentID: nil, folder: true, expanded: true)
        let childRow = row(child, depth: 1, parentID: folder)
        let siblingRow = row(sibling, depth: 0, parentID: nil)
        let rows = [folderRow, childRow, siblingRow]
        let ancestor: (UUID) -> SidebarDropRow? = { id in rows.first { $0.id == id } }

        let range = SidebarDropGeometry.allowedDepths(above: childRow, below: siblingRow, ancestor: ancestor)
        #expect(range == 0...1)

        let shallow = SidebarDropGeometry.depth(in: range, x: SidebarDropGeometry.rowLeading)
        let deep = SidebarDropGeometry.depth(in: range, x: SidebarDropGeometry.rowLeading + SidebarDropGeometry.indent)
        #expect(shallow == 0)
        #expect(deep == 1)
        #expect(SidebarDropGeometry.place(above: childRow, depth: shallow, ancestor: ancestor).parentID == nil)
        #expect(SidebarDropGeometry.place(above: childRow, depth: shallow, ancestor: ancestor).afterID == folder)
        #expect(SidebarDropGeometry.place(above: childRow, depth: deep, ancestor: ancestor).parentID == folder)
        #expect(SidebarDropGeometry.place(above: childRow, depth: deep, ancestor: ancestor).afterID == child)
    }

    @Test func gapUnderAnExpandedFolderOffersOnlyTheFirstChildSlot() {
        let folder = UUID()
        let child = UUID()
        let folderRow = row(folder, depth: 0, parentID: nil, folder: true, expanded: true)
        let childRow = row(child, depth: 1, parentID: folder)
        let rows = [folderRow, childRow]
        let ancestor: (UUID) -> SidebarDropRow? = { id in rows.first { $0.id == id } }

        let range = SidebarDropGeometry.allowedDepths(above: folderRow, below: childRow, ancestor: ancestor)
        #expect(range == 1...1)
        let placed = SidebarDropGeometry.place(above: folderRow, depth: 1, ancestor: ancestor)
        #expect(placed.parentID == folder)
        #expect(placed.afterID == nil)
    }

    @Test func endOfListAfterANestedItemCanUnindentToTheRoot() {
        let folder = UUID()
        let child = UUID()
        let folderRow = row(folder, depth: 0, parentID: nil, folder: true, expanded: true)
        let childRow = row(child, depth: 1, parentID: folder)
        let rows = [folderRow, childRow]
        let ancestor: (UUID) -> SidebarDropRow? = { id in rows.first { $0.id == id } }

        let range = SidebarDropGeometry.allowedDepths(above: childRow, below: nil, ancestor: ancestor)
        #expect(range == 0...1)
        let placed = SidebarDropGeometry.place(above: childRow, depth: 0, ancestor: ancestor)
        #expect(placed.parentID == nil)
        #expect(placed.afterID == folder)
    }

    @Test func emptyExpandedFolderSharesTheGapWithItsSibling() {
        let folder = UUID()
        let sibling = UUID()
        let folderRow = row(folder, depth: 0, parentID: nil, folder: true, expanded: true)
        let siblingRow = row(sibling, depth: 0, parentID: nil)
        let rows = [folderRow, siblingRow]
        let ancestor: (UUID) -> SidebarDropRow? = { id in rows.first { $0.id == id } }

        let range = SidebarDropGeometry.allowedDepths(above: folderRow, below: siblingRow, ancestor: ancestor)
        #expect(range == 0...1)
        let into = SidebarDropGeometry.place(above: folderRow, depth: 1, ancestor: ancestor)
        #expect(into.parentID == folder)
        #expect(into.afterID == nil)
        let beside = SidebarDropGeometry.place(above: folderRow, depth: 0, ancestor: ancestor)
        #expect(beside.parentID == nil)
        #expect(beside.afterID == folder)
    }

    @Test func favoritesAndTabsStayAtTheRoot() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let first = store.addItem(spaceID: space.id, section: .favorites, title: "One", url: URL(string: "https://one.example"))
        let second = store.addItem(spaceID: space.id, section: .favorites, title: "Two", url: URL(string: "https://two.example"))
        let context = SidebarDropContext.row(second, depth: 0, axis: .vertical)
        let proposal = SidebarDropResolver.proposal(
            context: context,
            location: CGPoint(x: 80, y: 2),
            size: CGSize(width: 200, height: 30),
            draggingID: nil,
            library: store
        )
        guard case .insert(let insertion) = proposal else {
            Issue.record("expected an insertion")
            return
        }
        #expect(insertion.depth == 0)
        #expect(insertion.parentID == nil)
        #expect(insertion.section == .favorites)
        #expect(insertion.position == .after(first.id))
    }

    @Test func indentationChoosesTheSiblingOrTheChild() {
        let store = LibraryStore(directory: nil)
        let space = store.createSpace(name: "Personal")
        let folder = store.addItem(spaceID: space.id, section: .pinned, kind: .folder, title: "Folder")
        let child = store.addItem(
            spaceID: space.id, section: .pinned, parentID: folder.id, title: "Child", url: URL(string: "https://child.example")
        )
        let sibling = store.addItem(spaceID: space.id, section: .pinned, title: "Sibling", url: URL(string: "https://sib.example"))
        let dragging = store.addItem(spaceID: space.id, section: .tabs, title: "Drag", url: URL(string: "https://drag.example"))
        let context = SidebarDropContext.row(sibling, depth: 0)
        let size = CGSize(width: 220, height: 30)

        let shallow = SidebarDropResolver.proposal(
            context: context,
            location: CGPoint(x: SidebarDropGeometry.rowLeading, y: 2),
            size: size,
            draggingID: dragging.id,
            library: store
        )
        let deep = SidebarDropResolver.proposal(
            context: context,
            location: CGPoint(x: SidebarDropGeometry.rowLeading + SidebarDropGeometry.indent, y: 2),
            size: size,
            draggingID: dragging.id,
            library: store
        )

        guard case .insert(let beside) = shallow, case .insert(let nested) = deep else {
            Issue.record("expected insertions")
            return
        }
        #expect(beside.depth == 0)
        #expect(beside.parentID == nil)
        #expect(beside.position == .after(folder.id))
        #expect(nested.depth == 1)
        #expect(nested.parentID == folder.id)
        #expect(nested.position == .after(child.id))
        #expect(beside.indicatorToken == sibling.id)
        #expect(beside.lineEdge == .top)
    }

    @Test func externalLinkUsesTheHTTPSURLWhenThePasteboardURLIsAFile() {
        let page = URL(string: "https://example.com/from-page")!
        let file = URL(fileURLWithPath: "/tmp/page.html")
        #expect(SidebarDropGeometry.externalWebURL(transferable: nil, object: page, text: "Drop me") == page)
        #expect(SidebarDropGeometry.externalWebURL(transferable: file, object: nil, text: "https://example.com/from-page") == page)
        #expect(SidebarDropGeometry.externalWebURL(transferable: nil, object: nil, text: "Drop me\nhttps://example.com/from-page") == page)
        #expect(SidebarDropGeometry.externalWebURL(transferable: nil, object: file, text: "not a url") == nil)
    }
}
