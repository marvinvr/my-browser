import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Drag payload for one sidebar row. `id` is the `SidebarItem` id.
nonisolated struct SidebarItemTransfer: Identifiable, Codable, Transferable, Sendable {
    var id: UUID

    static let prefix = "mybrowser-sidebar-item:"

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .myBrowserSidebarItem)
        ProxyRepresentation(exporting: { "\(prefix)\($0.id.uuidString)" })
    }

    static func id(from text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
}

nonisolated extension UTType {
    static let myBrowserSidebarItem = UTType(exportedAs: "ch.marvinvr.mybrowser.sidebar-item", conformingTo: .data)
}

/// Set from the drag payload closure, which is not on the main actor.
/// The session callbacks read it once they are back on the main actor.
enum SidebarDragBridge {
    nonisolated(unsafe) static var armedID: UUID?

    nonisolated static func arm(_ id: UUID) {
        armedID = id
    }
}

/// Where a pointer is inside a row, in that row's coordinate space.
nonisolated enum SidebarDropAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

nonisolated enum SidebarDropKind: Equatable, Sendable {
    /// A real row. `row` is set.
    case row
    /// Empty area that appends to the section root.
    case tail
    /// A control that inserts at the start of the section root (the New Tab row).
    case head
    /// A space icon. Internal items keep their section when they can.
    case space
}

nonisolated enum SidebarLineEdge: Equatable, Sendable {
    case top
    case bottom
    case leading
    case trailing
}

nonisolated struct SidebarDropRow: Equatable, Sendable {
    var id: UUID
    var depth: Int
    var parentID: UUID?
    var isFolder: Bool
    var isExpanded: Bool
}

nonisolated struct SidebarDropContext: Equatable, Sendable {
    var token: UUID
    var kind: SidebarDropKind
    var spaceID: UUID
    var section: SidebarItem.Section
    var axis: SidebarDropAxis
    var row: SidebarDropRow?

    static func row(_ item: SidebarItem, depth: Int, axis: SidebarDropAxis = .vertical) -> SidebarDropContext {
        SidebarDropContext(
            token: item.id,
            kind: .row,
            spaceID: item.spaceID,
            section: item.section,
            axis: axis,
            row: SidebarDropRow(
                id: item.id,
                depth: depth,
                parentID: item.parentID,
                isFolder: item.isFolder,
                isExpanded: item.isExpanded
            )
        )
    }

    static func tail(spaceID: UUID, section: SidebarItem.Section, token: UUID) -> SidebarDropContext {
        SidebarDropContext(token: token, kind: .tail, spaceID: spaceID, section: section, axis: .vertical, row: nil)
    }

    static func head(spaceID: UUID, section: SidebarItem.Section, token: UUID) -> SidebarDropContext {
        SidebarDropContext(token: token, kind: .head, spaceID: spaceID, section: section, axis: .vertical, row: nil)
    }

    static func space(_ spaceID: UUID) -> SidebarDropContext {
        SidebarDropContext(token: spaceID, kind: .space, spaceID: spaceID, section: .tabs, axis: .vertical, row: nil)
    }
}

/// Position among siblings. Mirrors `LibraryStore.Position` so the geometry stays nonisolated.
nonisolated enum SidebarDropPosition: Equatable, Sendable {
    case start
    case end
    case before(UUID)
    case after(UUID)

}

nonisolated struct SidebarInsertion: Equatable, Sendable {
    var spaceID: UUID
    var section: SidebarItem.Section
    var parentID: UUID?
    var position: SidebarDropPosition
    var depth: Int
    var indicatorToken: UUID
    var lineEdge: SidebarLineEdge
}

nonisolated enum SidebarDropProposal: Equatable {
    case insert(SidebarInsertion)
    case intoFolder(UUID)
    case ontoSpace(UUID)
    /// Drop the dragged site onto this row to create a split, or to join one.
    case intoSplit(UUID)
}

nonisolated enum SidebarDropZone: Equatable, Sendable {
    case before
    case after
    case into
    /// Middle of a site or split row. Dropping groups the dragged site with the row.
    case split
}

/// Pure hit testing for the insertion line. Rows are the visible outline, top to bottom.
nonisolated enum SidebarDropGeometry {
    static let indent: CGFloat = 14
    static let rowLeading: CGFloat = 6

    static func zone(y: CGFloat, height: CGFloat, treatsMiddleAsInto: Bool, treatsMiddleAsSplit: Bool = false) -> SidebarDropZone {
        let span = height > 1 ? height : 30
        let band = min(8, span * 0.3)
        if y < band { return .before }
        if y > span - band { return .after }
        if treatsMiddleAsInto { return .into }
        if treatsMiddleAsSplit { return .split }
        return y < span / 2 ? .before : .after
    }

    /// Depths whose insertion sits in the gap between `above` and `below`.
    /// An expanded folder with a visible child only offers the first-child slot in the gap under its header.
    /// The gap after a nested run can unindent down to the next row.
    static func allowedDepths(
        above: SidebarDropRow?,
        below: SidebarDropRow?,
        ancestor: (UUID) -> SidebarDropRow?
    ) -> ClosedRange<Int> {
        guard let above else { return 0...0 }
        if above.isFolder, above.isExpanded, contains(above.id, row: below, ancestor: ancestor) {
            let child = above.depth + 1
            return child...child
        }
        if above.isFolder, above.isExpanded {
            let floor = below?.depth ?? 0
            return floor...(above.depth + 1)
        }
        let maxDepth = above.depth
        let minDepth = below?.depth ?? 0
        if minDepth > maxDepth { return maxDepth...maxDepth }
        return minDepth...maxDepth
    }

    static func depth(in range: ClosedRange<Int>, x: CGFloat, origin: CGFloat = rowLeading) -> Int {
        let raw = Int(((x - origin) / indent).rounded())
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    /// `afterID == nil` means the start of `parentID`'s children (or the section root).
    static func place(
        above: SidebarDropRow?,
        depth: Int,
        ancestor: (UUID) -> SidebarDropRow?
    ) -> (parentID: UUID?, afterID: UUID?) {
        guard let above else { return (nil, nil) }
        if depth >= above.depth + 1 {
            return (above.id, nil)
        }
        var node = above
        var guardCount = 0
        while node.depth > depth, guardCount < 64 {
            guard let parentID = node.parentID, let parent = ancestor(parentID) else {
                return (nil, nil)
            }
            node = parent
            guardCount += 1
        }
        return (node.parentID, node.id)
    }

    static func contains(_ folderID: UUID, row: SidebarDropRow?, ancestor: (UUID) -> SidebarDropRow?) -> Bool {
        var current = row
        var guardCount = 0
        while let node = current, guardCount < 64 {
            if node.id == folderID { return true }
            guard let parentID = node.parentID else { return false }
            current = ancestor(parentID)
            guardCount += 1
        }
        return false
    }

    static func webURL(from url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    static func webURL(from text: String) -> URL? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for candidate in lines.isEmpty ? [text] : lines {
            guard case .url(let url) = URLInput.resolve(candidate) else { continue }
            if let web = webURL(from: url) { return web }
        }
        return nil
    }

    /// A page link may arrive as a transferable URL, an `NSURL` from WebKit, or plain text.
    /// The first http(s) value wins. A file URL falls through to the text.
    static func externalWebURL(transferable: URL?, object: URL?, text: String?) -> URL? {
        if let url = transferable.flatMap(webURL(from:)) { return url }
        if let url = object.flatMap(webURL(from:)) { return url }
        if let text { return webURL(from: text) }
        return nil
    }
}

/// Latest frame for a drop target. The drop callbacks are not main-actor isolated; they only read this.
final class SidebarDropBox: @unchecked Sendable {
    nonisolated(unsafe) var size: CGSize = .zero
    nonisolated(unsafe) var context: SidebarDropContext

    init(context: SidebarDropContext) {
        self.context = context
    }
}

@MainActor
enum SidebarDropResolver {
    static func proposal(
        context: SidebarDropContext,
        location: CGPoint,
        size: CGSize,
        draggingID: UUID?,
        library: LibraryStore
    ) -> SidebarDropProposal? {
        switch context.kind {
        case .space:
            return spaceProposal(context, draggingID: draggingID, library: library)
        case .tail, .head:
            return edgeProposal(context, draggingID: draggingID, library: library)
        case .row:
            guard let row = context.row else { return nil }
            return rowProposal(
                context,
                row: row,
                location: location,
                size: size,
                draggingID: draggingID,
                library: library
            )
        }
    }

    static func operation(draggingID: UUID?, proposal: SidebarDropProposal?) -> DropOperation {
        guard proposal != nil else { return .forbidden }
        return draggingID == nil ? .copy : .move
    }

    private static func spaceProposal(
        _ context: SidebarDropContext,
        draggingID: UUID?,
        library: LibraryStore
    ) -> SidebarDropProposal? {
        guard library.space(context.spaceID) != nil else { return nil }
        guard let draggingID else {
            return .insert(rootInsertion(context, position: .end, edge: .bottom))
        }
        guard let item = library.item(draggingID) else { return nil }
        let section = library.sectionForSpaceDrop(item)
        guard library.canDrop(draggingID, toSpace: context.spaceID, section: section, parentID: nil) else { return nil }
        return .ontoSpace(context.spaceID)
    }

    private static func edgeProposal(
        _ context: SidebarDropContext,
        draggingID: UUID?,
        library: LibraryStore
    ) -> SidebarDropProposal? {
        let position: SidebarDropPosition = context.kind == .head ? .start : .end
        let edge: SidebarLineEdge = context.kind == .head ? .bottom : .top
        let insertion = rootInsertion(context, position: position, edge: edge)
        if let draggingID, !library.canDrop(draggingID, toSpace: context.spaceID, section: context.section, parentID: nil) {
            return nil
        }
        return .insert(insertion)
    }

    private static func rootInsertion(
        _ context: SidebarDropContext,
        position: SidebarDropPosition,
        edge: SidebarLineEdge
    ) -> SidebarInsertion {
        SidebarInsertion(
            spaceID: context.spaceID,
            section: context.section,
            parentID: nil,
            position: position,
            depth: 0,
            indicatorToken: context.token,
            lineEdge: edge
        )
    }

    private static func rowProposal(
        _ context: SidebarDropContext,
        row: SidebarDropRow,
        location: CGPoint,
        size: CGSize,
        draggingID: UUID?,
        library: LibraryStore
    ) -> SidebarDropProposal? {
        let rows = visibleRows(section: context.section, spaceID: context.spaceID, library: library)
        let ancestor: (UUID) -> SidebarDropRow? = { id in rows.first { $0.id == id } }
        let intoOK = row.isFolder && context.section == .pinned && canEnter(row.id, draggingID: draggingID, library: library)
        let splitOK = !intoOK && canJoinSplit(row: row, draggingID: draggingID, section: context.section, library: library)
        let zone = zone(for: context.axis, location: location, size: size, into: intoOK, split: splitOK)
        if zone == .into {
            return .intoFolder(row.id)
        }
        if zone == .split {
            return .intoSplit(row.id)
        }

        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        let above: SidebarDropRow?
        let below: SidebarDropRow?
        let edge: SidebarLineEdge
        if zone == .before {
            above = index > 0 ? rows[index - 1] : nil
            below = row
            edge = context.axis == .horizontal ? .leading : .top
        } else {
            above = row
            below = index + 1 < rows.count ? rows[index + 1] : nil
            edge = context.axis == .horizontal ? .trailing : .bottom
        }

        let range = context.section == .pinned
            ? SidebarDropGeometry.allowedDepths(above: above, below: below, ancestor: ancestor)
            : 0...0
        let x = context.axis == .horizontal ? SidebarDropGeometry.rowLeading : location.x
        let depth = SidebarDropGeometry.depth(in: range, x: x)
        let placed = SidebarDropGeometry.place(above: above, depth: depth, ancestor: ancestor)
        let position: SidebarDropPosition = if let after = placed.afterID {
            .after(after)
        } else {
            .start
        }
        let insertion = SidebarInsertion(
            spaceID: context.spaceID,
            section: context.section,
            parentID: placed.parentID,
            position: position,
            depth: depth,
            indicatorToken: context.token,
            lineEdge: edge
        )
        if let draggingID,
           !library.canDrop(draggingID, toSpace: context.spaceID, section: context.section, parentID: placed.parentID) {
            return nil
        }
        return .insert(insertion)
    }

    private static func canEnter(_ folderID: UUID, draggingID: UUID?, library: LibraryStore) -> Bool {
        guard let draggingID else { return true }
        guard let spaceID = library.item(folderID)?.spaceID else { return false }
        return library.canDrop(draggingID, toSpace: spaceID, section: .pinned, parentID: folderID)
    }

    private static func zone(for axis: SidebarDropAxis, location: CGPoint, size: CGSize, into: Bool, split: Bool) -> SidebarDropZone {
        switch axis {
        case .horizontal:
            let width = size.width > 1 ? size.width : 1
            return location.x < width / 2 ? .before : .after
        case .vertical:
            return SidebarDropGeometry.zone(
                y: location.y,
                height: size.height,
                treatsMiddleAsInto: into,
                treatsMiddleAsSplit: split
            )
        }
    }

    /// A loose pinned or tabs site can join the hovered site, or a split that still has room.
    /// Favorites, folders, and a dragged split stay on the reorder path.
    private static func canJoinSplit(
        row: SidebarDropRow,
        draggingID: UUID?,
        section: SidebarItem.Section,
        library: LibraryStore
    ) -> Bool {
        guard section == .pinned || section == .tabs else { return false }
        guard let draggingID, draggingID != row.id, let dragged = library.item(draggingID) else { return false }
        guard dragged.kind == .site, dragged.section != .favorites, library.splitContainer(of: draggingID) == nil else { return false }
        guard let target = library.item(row.id), target.spaceID == dragged.spaceID else { return false }
        if target.isSplit {
            let members = library.splitMembers(of: target.id)
            return members.count < SidebarItem.maximumSplitMembers && !members.contains { $0.id == draggingID }
        }
        guard target.kind == .site, target.section != .favorites, library.splitContainer(of: target.id) == nil else { return false }
        return target.section == .pinned || target.section == .tabs
    }

    static func visibleRows(section: SidebarItem.Section, spaceID: UUID, library: LibraryStore) -> [SidebarDropRow] {
        if section != .pinned {
            return library.children(of: nil, section: section, in: spaceID).map {
                SidebarDropRow(id: $0.id, depth: 0, parentID: nil, isFolder: $0.isFolder, isExpanded: false)
            }
        }
        var rows: [SidebarDropRow] = []
        func walk(parent: UUID?, depth: Int) {
            for child in library.children(of: parent, section: .pinned, in: spaceID) {
                rows.append(SidebarDropRow(
                    id: child.id,
                    depth: depth,
                    parentID: parent,
                    isFolder: child.isFolder,
                    isExpanded: child.isExpanded
                ))
                if child.isFolder, child.isExpanded {
                    walk(parent: child.id, depth: depth + 1)
                }
            }
        }
        walk(parent: nil, depth: 0)
        return rows
    }
}

/// Shared drag feedback for one window. Drop callbacks reach it through `SidebarDragBridge` only for the armed id.
@Observable
final class SidebarInteraction {
    var draggingID: UUID?
    var proposal: SidebarDropProposal?
    var hoverToken: UUID?
    var editingID: UUID?
    /// Space whose name is being edited in the sidebar header.
    var editingSpaceID: UUID?

    @ObservationIgnored weak var model: BrowserModel?
    @ObservationIgnored private var expandTask: Task<Void, Never>?
    @ObservationIgnored private var expandID: UUID?
    @ObservationIgnored private var dragHaptics = SidebarDragHaptics()
    /// Mouse-up after a drag would also activate the row button (toggle a folder, select a site).
    @ObservationIgnored private var ignoreClicksUntil: Date?
    /// A drop session can keep sending updates after `performDrop`, which leaves the insertion line up.
    /// External link loads return before the pasteboard is read, so the line has to settle immediately.
    @ObservationIgnored private var dropGeneration = 0
    @ObservationIgnored private var settledGeneration = 0

    func shouldIgnoreRowClick() -> Bool {
        guard let until = ignoreClicksUntil else { return false }
        if until < Date() {
            ignoreClicksUntil = nil
            return false
        }
        return true
    }

    func noteDrag(phase: DragSession.Phase, ids: [UUID]) {
        switch phase {
        case .initial:
            draggingID = ids.first ?? SidebarDragBridge.armedID
            ignoreClicksUntil = Date().addingTimeInterval(1.5)
            beginHoverSession()
        case .active:
            draggingID = ids.first ?? SidebarDragBridge.armedID
            ignoreClicksUntil = Date().addingTimeInterval(1.5)
        case .ended, .dataTransferCompleted:
            draggingID = nil
            SidebarDragBridge.armedID = nil
            ignoreClicksUntil = Date().addingTimeInterval(0.4)
            settleDrop()
        @unknown default:
            draggingID = ids.first ?? SidebarDragBridge.armedID
            ignoreClicksUntil = Date().addingTimeInterval(1.5)
        }
    }

    func beginHoverSession() {
        if dropGeneration == settledGeneration {
            dropGeneration += 1
        }
    }

    /// Hides the insertion line. Later updates from the same drop session stay hidden.
    func settleDrop() {
        settledGeneration = dropGeneration
        proposal = nil
        hoverToken = nil
        cancelExpand()
        dragHaptics.reset()
    }

    private var dropIsSettled: Bool { dropGeneration == settledGeneration }

    func noteHover(
        context: SidebarDropContext,
        phase: DropSession.Phase,
        location: CGPoint,
        size: CGSize,
        draggedID: UUID?
    ) {
        if dropIsSettled {
            if proposal != nil || hoverToken != nil {
                proposal = nil
                hoverToken = nil
                cancelExpand()
            }
            return
        }
        switch phase {
        case .exiting, .ended:
            if hoverToken == context.token {
                proposal = nil
                hoverToken = nil
                cancelExpand()
            }
        case .dataTransferCompleted:
            break
        case .entering, .active:
            guard let model else { return }
            hoverToken = context.token
            let dragging = draggedID ?? draggingID ?? SidebarDragBridge.armedID
            let next = SidebarDropResolver.proposal(
                context: context,
                location: location,
                size: size,
                draggingID: dragging,
                library: model.library
            )
            if proposal != next {
                proposal = next
                if let moment = dragHaptics.note(next) {
                    Haptics.play(moment)
                }
            }
            if case .intoFolder(let folder) = next {
                scheduleExpand(folder)
            } else {
                cancelExpand()
            }
        @unknown default:
            break
        }
    }

    func operation(context: SidebarDropContext, location: CGPoint, size: CGSize, draggedID: UUID?) -> DropOperation {
        guard let model else { return .copy }
        let dragging = draggedID ?? draggingID ?? SidebarDragBridge.armedID
        let proposal = SidebarDropResolver.proposal(
            context: context,
            location: location,
            size: size,
            draggingID: dragging,
            library: model.library
        )
        return SidebarDropResolver.operation(draggingID: dragging, proposal: proposal)
    }

    func performItem(_ id: UUID, context: SidebarDropContext, location: CGPoint, size: CGSize) {
        guard let model else { return }
        guard let proposal = SidebarDropResolver.proposal(
            context: context,
            location: location,
            size: size,
            draggingID: id,
            library: model.library
        ) else { return }
        apply(proposal, draggingID: id, url: nil)
    }

    /// A link from a page or another app. Anything that is not http or https is ignored.
    func performExternal(_ url: URL, context: SidebarDropContext, location: CGPoint, size: CGSize) {
        guard let clean = SidebarDropGeometry.webURL(from: url) else { return }
        guard let model else { return }
        guard let proposal = SidebarDropResolver.proposal(
            context: context,
            location: location,
            size: size,
            draggingID: nil,
            library: model.library
        ) else { return }
        apply(proposal, draggingID: nil, url: clean)
    }

    func performText(_ text: String, context: SidebarDropContext, location: CGPoint, size: CGSize) {
        guard let url = SidebarDropGeometry.webURL(from: text) else { return }
        performExternal(url, context: context, location: location, size: size)
    }

    private func apply(_ proposal: SidebarDropProposal, draggingID: UUID?, url: URL?) {
        guard let model else { return }
        switch proposal {
        case .insert(let insertion):
            let position = Self.libraryPosition(insertion.position)
            if let draggingID {
                model.moveItem(
                    draggingID,
                    toSpace: insertion.spaceID,
                    section: insertion.section,
                    parentID: insertion.parentID,
                    position: position
                )
            } else if let url {
                model.insertDroppedURL(
                    url,
                    toSpace: insertion.spaceID,
                    section: insertion.section,
                    parentID: insertion.parentID,
                    position: position
                )
            }
        case .intoFolder(let folderID):
            guard let folder = model.library.item(folderID) else { return }
            if let draggingID {
                model.moveItem(draggingID, toSpace: folder.spaceID, section: .pinned, parentID: folderID, position: .end)
            } else if let url {
                model.insertDroppedURL(url, toSpace: folder.spaceID, section: .pinned, parentID: folderID, position: .end)
            }
            if model.library.item(folderID)?.isExpanded == false {
                model.toggleExpanded(folderID)
            }
        case .ontoSpace(let spaceID):
            guard let draggingID, let item = model.library.item(draggingID) else { return }
            let section = model.library.sectionForSpaceDrop(item)
            model.moveItem(draggingID, toSpace: spaceID, section: section, parentID: nil, position: .end)
        case .intoSplit(let targetID):
            guard joinSplit(draggingID: draggingID, targetID: targetID) else { return }
        }
        Haptics.play(.drop)
        self.proposal = nil
        hoverToken = nil
        cancelExpand()
    }

    /// The hovered row stays the anchor: a site becomes a split there, a split gains the dragged pane.
    private func joinSplit(draggingID: UUID?, targetID: UUID) -> Bool {
        guard let model, let draggingID, let target = model.library.item(targetID) else { return false }
        if target.isSplit {
            let index = model.library.splitMembers(of: targetID).count
            return model.addToSplit(tabID: draggingID, splitID: targetID, at: index) != nil
        }
        return model.createSplit(tabIDs: [targetID, draggingID]) != nil
    }

    private static func libraryPosition(_ position: SidebarDropPosition) -> LibraryStore.Position {
        switch position {
        case .start: .start
        case .end: .end
        case .before(let id): .before(id)
        case .after(let id): .after(id)
        }
    }

    private func scheduleExpand(_ folderID: UUID) {
        guard expandID != folderID else { return }
        expandTask?.cancel()
        expandID = folderID
        expandTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            guard self.expandID == folderID, let model = self.model else { return }
            guard let folder = model.library.item(folderID), folder.isFolder, !folder.isExpanded else { return }
            model.toggleExpanded(folderID)
            Haptics.play(.folderExpand)
        }
    }

    private func cancelExpand() {
        expandTask?.cancel()
        expandTask = nil
        expandID = nil
    }
}
