import SwiftUI

/// Settings scene (⌘,). General holds the search engine; Appearance holds the address bar and Dock icon.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 460, height: 300)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(SearchEngine.defaultsKey) private var searchEngine: SearchEngine = .google
    @AppStorage(SyncController.enabledDefaultsKey) private var iCloudSyncEnabled = false

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
                Toggle("iCloud Sync (beta)", isOn: iCloudSync)
                    .disabled(!SyncController.isContainerConfigured)
            } footer: {
                if !SyncController.isContainerConfigured {
                    Text("Requires iCloud container — coming soon")
                }
            }
        }
        .formStyle(.grouped)
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
