import SwiftUI

/// Placeholder sidebar. Later waves replace this with favorites, pins and tabs.
struct SidebarView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let name = model.selectedSpace?.name {
                Text(name)
                    .font(.headline)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 40)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}
