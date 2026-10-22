import Foundation
import Observation

/// Loads detected browsers and runs one import off the main actor until the plan is applied.
@Observable
final class ImportSession {
    var sources: [ImportSource] = []
    var selectedID: String?
    var isLoading = false
    var isWorking = false
    var bookmarkBarAsFolder = true
    var includeUnpinned = false
    var target: ImportTarget = .newSpace
    var summary: String?
    var note: String?
    var errorText: String?

    private var didStart = false

    /// `MYBROWSER_DEBUG_IMPORT_SELECT` matches a source id or title so a snapshot can show that row.
    private static func initialSelection(in found: [ImportSource]) -> String? {
        #if DEBUG
        if let wanted = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_IMPORT_SELECT"], !wanted.isEmpty {
            let needle = wanted.lowercased()
            if let match = found.first(where: {
                $0.id.lowercased().contains(needle) || $0.title.lowercased().contains(needle)
            }) {
                return match.id
            }
        }
        #endif
        return found.first?.id
    }

    var selectedSource: ImportSource? {
        sources.first { $0.id == selectedID }
    }

    func load() {
        guard !didStart else { return }
        didStart = true
        isLoading = true
        let root = ImportDiscovery.applicationSupportDirectory()
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ImportDiscovery.sources(in: root)
            }.value
            sources = found
            selectedID = Self.initialSelection(in: found)
            isLoading = false
        }
    }

    /// Parses off the main actor, then applies on it. Nil means the file could not be read.
    func run(in library: LibraryStore) async -> ImportResult? {
        guard let source = selectedSource, !isWorking, summary == nil else { return nil }
        isWorking = true
        errorText = nil
        defer { isWorking = false }

        let file = source.fileURL
        let kind = source.kind
        let spaceName = source.profileName
        let symbol = source.symbol
        let color = source.color
        let names = source.arcProfileNames
        let barFolder = bookmarkBarAsFolder
        let unpinned = includeUnpinned
        let destination = destinationID(for: source)

        let plan = await Task.detached(priority: .userInitiated) { () -> ImportPlan? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            switch kind {
            case .arcSidebar:
                return ArcSidebarParser.read(data: data, includeUnpinned: unpinned, profileNames: names)?.plan
            case .chromium:
                return ChromiumBookmarkParser.plan(
                    data: data,
                    options: ChromiumBookmarkParser.Options(
                        spaceName: spaceName,
                        symbol: symbol,
                        color: color,
                        bookmarkBarAsFolder: barFolder
                    )
                )
            }
        }.value

        guard let plan else {
            errorText = "Couldn’t read that library."
            return nil
        }
        let result = library.apply(plan, to: destination)
        summary = result.summary
        let notes = result.notes.joined(separator: " ")
        note = notes.isEmpty ? nil : notes
        return result
    }

    private func destinationID(for source: ImportSource) -> UUID? {
        guard case .chromium = source.kind, case .space(let id) = target else { return nil }
        return id
    }
}

enum ImportTarget: Hashable {
    case newSpace
    case space(UUID)
}
