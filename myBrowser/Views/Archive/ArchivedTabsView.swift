import SwiftUI

/// Searchable list of tabs the archiver closed. Reopening restores the tab and its history.
struct ArchivedTabsView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Archived Tabs")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No Archived Tabs" : "No Matches", systemImage: "archivebox")
                } description: {
                    Text(query.isEmpty
                         ? "Unpinned tabs you have not opened are kept here for 30 days."
                         : "Try a different title or address.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    Button {
                        model.reopenArchivedTab(entry.id)
                    } label: {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 460, height: 520)
        .background { ArchiveWindowMarker() }
    }

    private var filtered: [SessionStore.ArchivedTab] {
        let newestFirst = Array(model.session.archivedTabs.reversed())
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return newestFirst }
        return newestFirst.filter { entry in
            if entry.item.title.localizedStandardContains(trimmed) { return true }
            if entry.item.url?.absoluteString.localizedStandardContains(trimmed) == true { return true }
            let space = model.library.space(entry.item.spaceID)?.name ?? ""
            return space.localizedStandardContains(trimmed)
        }
    }

    private func row(_ entry: SessionStore.ArchivedTab) -> some View {
        HStack(spacing: 10) {
            FaviconView(
                image: entry.item.url.flatMap { model.favicons.cachedFavicon(for: $0) },
                url: entry.item.url,
                title: entry.item.title
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.title.isEmpty ? (SidebarTitle.host(of: entry.item.url) ?? "Tab") : entry.item.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(detail(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Reopen")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func detail(_ entry: SessionStore.ArchivedTab) -> String {
        let host = SidebarTitle.host(of: entry.item.url) ?? entry.item.url?.absoluteString ?? ""
        let space = model.library.space(entry.item.spaceID)?.name
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: entry.archivedAt, relativeTo: .now)
        return [host, space, when].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }
}

/// Tags the sheet window so a debug snapshot can pick it out from the main window.
private struct ArchiveWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { tag(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { tag(view) }
    }

    private func tag(_ view: NSView) {
        view.window?.identifier = NSUserInterfaceItemIdentifier("archived-tabs")
        view.window?.title = "Archived Tabs"
    }
}
