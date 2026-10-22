#if DEBUG
import SwiftUI

/// In-memory library for SwiftUI previews. Never used by the running app.
extension LibraryStore {
    static func sample() -> LibraryStore {
        let store = LibraryStore(directory: nil)
        let personal = store.createSpace(name: "Personal", symbol: "person.fill", color: .blue)
        let work = store.createSpace(name: "Work", symbol: "briefcase.fill", color: .orange)

        func site(
            _ spaceID: UUID,
            _ section: SidebarItem.Section,
            _ title: String,
            _ url: String,
            parent: UUID? = nil
        ) {
            store.addItem(
                spaceID: spaceID,
                section: section,
                parentID: parent,
                title: title,
                url: URL(string: url)
            )
        }

        site(personal.id, .favorites, "GitHub", "https://github.com")
        site(personal.id, .favorites, "Apple", "https://www.apple.com")
        site(personal.id, .favorites, "Hacker News", "https://news.ycombinator.com")
        site(personal.id, .favorites, "Wikipedia", "https://en.wikipedia.org")
        site(personal.id, .favorites, "YouTube", "https://www.youtube.com")
        site(personal.id, .favorites, "Maps", "https://maps.apple.com")

        let reading = store.addItem(spaceID: personal.id, section: .pinned, kind: .folder, title: "Reading")
        site(personal.id, .pinned, "Swift Forums", "https://forums.swift.org", parent: reading.id)
        let specs = store.addItem(
            spaceID: personal.id,
            section: .pinned,
            kind: .folder,
            parentID: reading.id,
            title: "Specs"
        )
        site(personal.id, .pinned, "Swift Evolution", "https://github.com/swiftlang/swift-evolution", parent: specs.id)

        let later = store.addItem(spaceID: personal.id, section: .pinned, kind: .folder, title: "Later")
        store.updateItem(later.id) { $0.isExpanded = false }
        site(personal.id, .pinned, "Pinboard", "https://pinboard.in", parent: later.id)
        site(personal.id, .pinned, "Are.na", "https://www.are.na")

        site(personal.id, .tabs, "The New York Times", "https://www.nytimes.com")
        site(personal.id, .tabs, "Apple Developer Documentation", "https://developer.apple.com/documentation/")
        store.addItem(spaceID: personal.id, section: .tabs, title: "New Tab")

        site(work.id, .favorites, "Linear", "https://linear.app")
        site(work.id, .favorites, "Figma", "https://www.figma.com")
        site(work.id, .tabs, "Slack", "https://app.slack.com")
        return store
    }
}

extension BrowserModel {
    static func preview(sidebarVisible: Bool = true) -> BrowserModel {
        let library = LibraryStore.sample()
        let session = SessionStore(directory: nil)
        let space = library.orderedSpaces.first ?? library.ensureDefaultSpace()
        session.selectedSpaceID = space.id
        session.isSidebarVisible = sidebarVisible
        if let first = library.children(of: nil, section: .favorites, in: space.id).first {
            session.selectedItemBySpace[space.id] = first.id
        }
        return BrowserModel(library: library, session: session)
    }
}

struct PreviewHost<Content: View>: View {
    @State private var model: BrowserModel
    @State private var extensions: ExtensionManager
    private var width: CGFloat?
    private var height: CGFloat?
    private var content: Content

    init(
        sidebarVisible: Bool = true,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        let model = BrowserModel.preview(sidebarVisible: sidebarVisible)
        _model = State(initialValue: model)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mybrowser-preview-extensions", directoryHint: .isDirectory)
        let extensions = ExtensionManager(directory: directory)
        extensions.connectOwner()
        _extensions = State(initialValue: extensions)
        self.width = width
        self.height = height
        self.content = content()
    }

    var body: some View {
        content
            .environment(model)
            .environment(extensions)
            .frame(width: width, height: height)
    }
}
#endif
