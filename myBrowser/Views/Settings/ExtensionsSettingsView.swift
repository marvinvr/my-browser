import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Extensions. Install, enable per profile, remove, and open options.
struct ExtensionsSettingsView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(ExtensionManager.self) private var extensions

    @State private var storeText = ""

    var body: some View {
        Form {
            Section {
                if extensions.records.isEmpty {
                    Text("No extensions installed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(extensions.records) { record in
                        ExtensionSettingsRow(record: record)
                    }
                }
            }

            Section("Install") {
                Button("Install from File…") {
                    installFromFile()
                }
                .disabled(extensions.isBusy)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Chrome Web Store")
                    TextField("", text: $storeText, prompt: Text("URL or extension id"))
                        .textFieldStyle(.roundedBorder)
                }
                Button("Install from Chrome Web Store") {
                    let text = storeText
                    Task {
                        await extensions.installFromChromeWebStore(text)
                        if extensions.lastError == nil {
                            storeText = ""
                        }
                    }
                }
                .disabled(extensions.isBusy || storeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if extensions.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = extensions.lastError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Dismiss") { extensions.clearError() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func installFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Install"
        panel.message = "Choose an unpacked extension folder, or a .zip, .xpi, or .crx package."
        var types: [UTType] = [.zip, .folder]
        if let xpi = UTType(filenameExtension: "xpi") { types.append(xpi) }
        if let crx = UTType(filenameExtension: "crx") { types.append(crx) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await extensions.install(from: url) }
    }
}

private struct ExtensionSettingsRow: View {
    var record: ExtensionRecord

    @Environment(BrowserModel.self) private var model
    @Environment(ExtensionManager.self) private var extensions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .font(.body)
                    Text(versionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if record.hasOptionsPage {
                    Button("Options") { extensions.openOptions(id: record.id) }
                        .disabled(currentProfileID.map { record.isEnabled(in: $0) } != true)
                }
                Button("Remove", role: .destructive) { confirmRemove() }
            }

            if !profiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enabled in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(profiles, id: \.id) { profile in
                        HStack(spacing: 8) {
                            Text(profile.name)
                            Spacer(minLength: 8)
                            ProfileSwitch(isOn: isEnabled(profile.id)) { enabled in
                                Task { await extensions.setEnabled(enabled, id: record.id, profileID: profile.id) }
                            }
                            .disabled(extensions.isBusy)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var versionLine: String {
        let source: String
        switch record.source {
        case .folder: source = "Unpacked folder"
        case .zip: source = "Zip"
        case .xpi: source = "Firefox add-on"
        case .crx: source = "Chrome package"
        case .chromeWebStore: source = "Chrome Web Store"
        }
        if record.summary.isEmpty { return "Version \(record.version) · \(source)" }
        return "Version \(record.version) · \(source)\n\(record.summary)"
    }

    private var currentProfileID: UUID? { model.selectedSpace?.profileID }

    private var profiles: [(id: UUID, name: String)] {
        var seen: [UUID: String] = [:]
        for space in model.library.orderedSpaces {
            if seen[space.profileID] == nil {
                seen[space.profileID] = model.library.profile(space.profileID)?.name ?? space.name
            }
        }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var icon: some View {
        Group {
            if let image = extensions.icon(for: record) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    /// Reads the live catalog. A `Form` `Toggle` was drawing off while this profile was enabled.
    private func isEnabled(_ profileID: UUID) -> Bool {
        extensions.records.first { $0.id == record.id }?.isEnabled(in: profileID) ?? false
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove \(record.name)?"
        alert.informativeText = "The extension will be removed from every profile."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            extensions.remove(id: record.id)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// Profile enablement. A `Form` `Toggle` ignored the initial on state, and `NSSwitch`
/// cacheDisplay drops the accent tint, so the on state is drawn here.
private struct ProfileSwitch: View {
    var isOn: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isOn)
        } label: {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.16))
                .frame(width: 36, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.2), radius: 0.6, y: 0.5)
                        .padding(2)
                }
                .animation(.spring(duration: 0.22, bounce: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enabled")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
