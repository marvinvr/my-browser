import AppKit
import SwiftUI

/// File → Import…, and the first-launch welcome sheet (`offersStartFresh`).
struct ImportSheet: View {
    var model: BrowserModel
    var offersStartFresh: Bool
    var onComplete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var session = ImportSession()
    @State private var icons: [String: NSImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                sourcesSection
                if let source = session.selectedSource, session.summary == nil {
                    Section("Options") {
                        options(for: source)
                    }
                }
                if session.summary != nil || session.errorText != nil {
                    Section {
                        if let summary = session.summary {
                            Text(summary)
                        }
                        if let note = session.note {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let errorText = session.errorText {
                            Text(errorText)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        // Grouped form sections paint their own cards. The title and buttons sit
        // outside those cards, so the sheet itself needs a surface or they float on the page.
        .background(Color(nsColor: .windowBackgroundColor))
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
        .background { ImportWindowMarker(identifier: offersStartFresh ? "welcome" : "import") }
        .onAppear {
            session.load()
        }
        .onChange(of: session.sources.map(\.id)) { _, _ in
            loadIcons()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if offersStartFresh, let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .padding(.bottom, 4)
            }
            Text(offersStartFresh ? "Welcome to myBrowser" : "Import")
                .font(.title2.weight(.semibold))
            Text(offersStartFresh
                ? "Bring in spaces and bookmarks, or start with an empty sidebar."
                : "Copy bookmarks or an Arc sidebar into this library. Cookies stay where they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sourcesSection: some View {
        Section(offersStartFresh ? "Import from" : "Source") {
            if session.isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for browsers…")
                        .foregroundStyle(.secondary)
                }
            } else if session.sources.isEmpty {
                Text("No Chrome, Brave, Edge, Vivaldi, or Arc library was found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.sources) { source in
                    sourceRow(source)
                }
            }
        }
    }

    private func sourceRow(_ source: ImportSource) -> some View {
        let selected = session.selectedID == source.id
        return Button {
            session.selectedID = source.id
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: icons[source.id] ?? SourceIcon.image(
                    bundleIdentifier: source.bundleIdentifier,
                    fallback: source.fallbackSymbol
                ))
                .resizable()
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .foregroundStyle(.primary)
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isWorking || session.summary != nil)
        .accessibilityLabel("\(source.title), \(source.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func options(for source: ImportSource) -> some View {
        @Bindable var session = session
        switch source.kind {
        case .arcSidebar:
            Toggle("Include unpinned tabs", isOn: $session.includeUnpinned)
            Text("Pinned folders keep their order. Favorites go into the first space of each profile. Cookies are not imported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .chromium:
            Picker("Add to", selection: $session.target) {
                Text("New space “\(source.profileName)”").tag(ImportTarget.newSpace)
                ForEach(model.library.orderedSpaces) { space in
                    Text(space.name).tag(ImportTarget.space(space.id))
                }
            }
            Toggle("Keep the bookmarks bar in a folder", isOn: $session.bookmarkBarAsFolder)
            Text("Other bookmarks and mobile bookmarks are always folders. javascript links are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if session.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text("Importing…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.summary == nil {
                if offersStartFresh {
                    Button("Start Fresh") { finish() }
                        .disabled(session.isWorking)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(session.isWorking)
                }
                Button("Import") {
                    Task { await importSelected() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.selectedSource == nil || session.isLoading || session.isWorking)
            } else {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private func importSelected() async {
        guard let result = await session.run(in: model.library) else { return }
        if let id = result.spaceIDs.first {
            model.selectSpace(id)
        }
        if offersStartFresh {
            removeEmptyPersonal(keeping: Set(result.spaceIDs))
        }
        loadIcons()
    }

    /// The auto-created Personal space is empty on a first launch. Drop it once real spaces exist.
    private func removeEmptyPersonal(keeping imported: Set<UUID>) {
        guard model.library.orderedSpaces.count > 1 else { return }
        for space in model.library.orderedSpaces where space.name == "Personal" && !imported.contains(space.id) {
            let empty = SidebarItem.Section.allCases.allSatisfy { section in
                model.library.children(of: nil, section: section, in: space.id).isEmpty
            }
            if empty {
                model.deleteSpace(space.id)
            }
        }
    }

    private func finish() {
        onComplete?()
        dismiss()
    }

    private func loadIcons() {
        var next: [String: NSImage] = [:]
        for source in session.sources {
            next[source.id] = SourceIcon.image(
                bundleIdentifier: source.bundleIdentifier,
                fallback: source.fallbackSymbol
            )
        }
        icons = next
    }
}

/// Tags the sheet window so a debug snapshot can pick it out from the main window.
private struct ImportWindowMarker: NSViewRepresentable {
    var identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { tag(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { tag(view) }
    }

    private func tag(_ view: NSView) {
        view.window?.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
}

enum SourceIcon {
    static func image(bundleIdentifier: String?, fallback: String) -> NSImage {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            return icon
        }
        let symbol = NSImage(systemSymbolName: fallback, accessibilityDescription: nil) ?? NSImage()
        symbol.size = NSSize(width: 28, height: 28)
        symbol.isTemplate = true
        return symbol
    }
}
