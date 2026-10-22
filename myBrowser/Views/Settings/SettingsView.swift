import SwiftUI

/// Settings scene (⌘,). General holds the search engine; Appearance holds the address bar and Dock icon; Extensions holds installed web extensions.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            ExtensionsSettingsView()
                .tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 520, height: 460)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(SearchEngine.defaultsKey) private var searchEngine: SearchEngine = .google

    var body: some View {
        Form {
            Picker("Default search engine", selection: $searchEngine) {
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
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
