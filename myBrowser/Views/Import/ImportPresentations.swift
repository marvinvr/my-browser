import SwiftUI

/// Presents Import… and, on a first launch, the welcome sheet.
struct ImportPresentations: ViewModifier {
    var model: BrowserModel
    @AppStorage(Onboarding.completedKey) private var hasCompletedOnboarding = false
    @State private var showWelcome = false

    func body(content: Content) -> some View {
        // Read the flag here so this view updates when the menu flips it.
        let presentingImport = model.isPresentingImport
        content
            .sheet(isPresented: Binding(
                get: { presentingImport },
                set: { model.isPresentingImport = $0 }
            )) {
                ImportSheet(model: model, offersStartFresh: false)
            }
            .background {
                Color.clear
                    .sheet(isPresented: $showWelcome) {
                        ImportSheet(model: model, offersStartFresh: true) {
                            hasCompletedOnboarding = true
                        }
                        .interactiveDismissDisabled()
                    }
            }
            .onAppear(perform: appear)
    }

    private func appear() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["MYBROWSER_DEBUG_ONBOARDING"] == "1" {
            showWelcome = true
            return
        }
        if env["MYBROWSER_DEBUG_IMPORT"] == "1" {
            model.isPresentingImport = true
            return
        }
        if env["MYBROWSER_DEBUG_LIBRARY"] != nil {
            return
        }
        #endif
        if !hasCompletedOnboarding {
            showWelcome = true
        }
    }
}

extension View {
    func importPresentations(model: BrowserModel) -> some View {
        modifier(ImportPresentations(model: model))
    }
}
