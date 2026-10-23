import AppKit
import SwiftUI

/// Hosts the selected site, or every pane of the selected split.
/// Web views are created once and moved between panes. A resize does not rebuild them.
struct WebContentView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        let content = model.displayedContent
        return ZStack {
            if let content {
                SplitCanvas(content: content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: content == nil)
        .background {
            NavigationSwipeMonitor()
                .allowsHitTesting(false)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Press ⌘T to open a tab")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
