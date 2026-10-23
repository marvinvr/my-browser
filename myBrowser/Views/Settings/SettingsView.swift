import AuthenticationServices
import SwiftUI

/// Settings scene (⌘,). General holds the search engine, tab archive, and iCloud Sync; Appearance holds the address bar and Dock icon; Websites holds notification decisions; Extensions holds installed web extensions.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            WebsiteSettingsView()
                .tabItem { Label("Websites", systemImage: "bell") }
            ExtensionsSettingsView()
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 560, height: 560)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(SearchEngine.defaultsKey) private var searchEngine: SearchEngine = .google
    @AppStorage(TabArchiveInterval.defaultsKey) private var archiveAfter: TabArchiveInterval = .twentyFourHours
    @AppStorage(PictureInPictureSettings.autoDefaultsKey) private var autoPictureInPicture = true
    @AppStorage(SyncController.enabledDefaultsKey) private var iCloudSyncEnabled = false
    @Environment(PasskeyBroker.self) private var passkeys
    @Environment(SyncController.self) private var sync

    private var iCloudSync: Binding<Bool> {
        Binding(
            get: { SyncController.isContainerConfigured && iCloudSyncEnabled },
            set: { newValue in
                guard SyncController.isContainerConfigured else { return }
                iCloudSyncEnabled = newValue
            }
        )
    }

    var body: some View {
        Form {
            Picker("Default search engine", selection: $searchEngine) {
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            Section {
                LabeledContent("Archive tabs after") {
                    HStack(spacing: 6) {
                        Picker("Archive tabs after", selection: $archiveAfter) {
                            ForEach(TabArchiveInterval.allCases) { interval in
                                Text(interval.label).tag(interval)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("archiveTabsAfter")
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .help(TabArchiveInterval.explanation)
                            .accessibilityLabel("About archiving tabs")
                    }
                }
            } header: {
                Text("Tabs")
            }

            Section {
                Toggle("Automatic Picture in Picture", isOn: $autoPictureInPicture)
            } footer: {
                Text("A playing video moves to Picture in Picture when you leave its tab or the window.")
            }

            Section {
                Toggle("iCloud Sync (beta)", isOn: iCloudSync)
                    .disabled(!SyncController.isContainerConfigured)
            } footer: {
                Text(syncCaption)
            }

            Section {
                LabeledContent("Passkeys", value: passkeys.statusLabel)
                if passkeys.access != .authorized {
                    Button("Allow Passkeys…") { passkeys.requestAccess() }
                        .disabled(!passkeys.entitlementInSignature)
                }
                Button("AutoFill Providers…") {
                    ASSettingsHelper.openCredentialProviderAppSettings { _ in }
                }
            } footer: {
                Text(passkeys.footer)
            }
            .onAppear { passkeys.refresh() }
        }
        .formStyle(.grouped)
    }

    private var syncCaption: String {
        guard SyncController.isContainerConfigured else {
            return "Requires iCloud container — coming soon"
        }
        guard iCloudSyncEnabled else { return SyncController.offStatus }
        return sync.statusText.isEmpty ? SyncController.syncingStatus : sync.statusText
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(AddressBarPosition.defaultsKey) private var addressBarPosition: AddressBarPosition = .top
    @AppStorage(AppIconVariant.defaultsKey) private var appIcon: AppIconVariant = .light

    var body: some View {
        Form {
            Picker("Address bar position", selection: $addressBarPosition) {
                ForEach(AddressBarPosition.allCases) { position in
                    Text(position.label).tag(position)
                }
            }
            .pickerStyle(.radioGroup)

            Picker("App icon", selection: $appIcon) {
                ForEach(AppIconVariant.allCases) { variant in
                    Text(variant.label).tag(variant)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
        .onChange(of: appIcon) { _, variant in
            AppIconApplier.apply(variant)
        }
    }
}
