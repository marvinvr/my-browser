import SwiftUI

/// Settings scene (⌘,). General holds the search engine; Appearance holds the address bar.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 460, height: 280)
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

    var body: some View {
        Form {
            Picker("Address bar position", selection: $addressBarPosition) {
                ForEach(AddressBarPosition.allCases) { position in
                    Text(position.label).tag(position)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
    }
}
