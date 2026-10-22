import SwiftUI

/// Placeholder content card. Later waves host the selected tab's web view here.
struct WebContentView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.background)
            .overlay {
                Text("No tab")
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
