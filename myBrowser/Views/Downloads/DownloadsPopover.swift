import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Safari-style list anchored to the toolbar button. Icons, progress, and quiet actions.
struct DownloadsPopover: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        let downloads = model.downloads
        let items = downloads.popoverRecords
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Downloads")
                    .font(.headline)
                Spacer(minLength: 8)
                Button("Clear") { downloads.clearPopover() }
                    .buttonStyle(.borderless)
                    .disabled(!downloads.canClearPopover())
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.5)

            if items.isEmpty {
                Text("No recent downloads")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { record in
                            DownloadRow(record: record, subtitle: downloads.subtitle(for: record))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 340)
    }
}

/// Full history for the current profile. Cmd+Shift+J.
struct DownloadsPage: View {
    @Environment(BrowserModel.self) private var model
    @State private var query = ""

    var body: some View {
        let downloads = model.downloads
        let items = downloads.history(matching: query)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Downloads")
                    .font(.title2)
                Spacer(minLength: 12)
                Button("Clear History") { downloads.clearHistory() }
                    .disabled(!downloads.records.contains { $0.profileID == downloads.visibleProfileID && !$0.isActive })
                Button("Done") { downloads.isPagePresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 12)

            if items.isEmpty {
                Text(query.isEmpty ? "Downloads are saved to your Downloads folder." : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { record in
                            DownloadRow(record: record, subtitle: downloads.subtitle(for: record))
                            Divider().opacity(0.35).padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DownloadRow: View {
    var record: DownloadRecord
    var subtitle: String

    @Environment(BrowserModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if record.state == .downloading {
                    DownloadBar(fraction: record.fraction)
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard record.state == .finished else { return }
            model.openDownload(record.id)
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.filename), \(subtitle)")
        .accessibilityAddTraits(record.state == .finished ? .isButton : [])
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch record.state {
            case .downloading:
                iconButton("pause.fill", help: "Pause") { model.downloads.pause(record.id) }
                iconButton("xmark", help: "Cancel") { model.downloads.cancel(record.id) }
            case .paused:
                iconButton("play.fill", help: "Resume") { model.downloads.resume(record.id) }
                iconButton("xmark", help: "Cancel") { model.downloads.cancel(record.id) }
            case .failed, .cancelled:
                if record.resumeData != nil {
                    iconButton("play.fill", help: "Resume") { model.downloads.resume(record.id) }
                }
                iconButton("arrow.clockwise", help: "Retry") { model.downloads.retry(record.id) }
            case .finished:
                iconButton("magnifyingglass", help: "Show in Finder") { model.downloads.reveal(record.id) }
            }
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .help("More")
        }
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Show in Finder") { model.downloads.reveal(record.id) }
            .disabled(model.downloads.existingFile(record.id) == nil)
        Button("Open") { model.openDownload(record.id) }
            .disabled(record.state != .finished)
        Button("Open in Default App") { model.openDownload(record.id, inDefaultApp: true) }
            .disabled(record.state != .finished)
        Divider()
        Button("Remove") { model.downloads.remove(record.id) }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var icon: NSImage {
        if let url = model.downloads.existingFile(record.id) {
            return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        }
        let ext = (record.filename as NSString).pathExtension
        if let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

/// Thin bar. Known progress fills it. An unknown size leaves the track empty.
private struct DownloadBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction {
                    Capsule()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: max(2, width * CGFloat(min(max(fraction, 0), 1))))
                }
            }
        }
        .frame(height: 3)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}
