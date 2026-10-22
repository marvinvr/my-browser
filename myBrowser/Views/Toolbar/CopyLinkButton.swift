import SwiftUI

/// Link icon at the leading edge of the address field. Copies the current page URL.
/// Menu item ⌘⇧C calls `BrowserModel.copyCurrentLink()`, which bumps `linkCopyGeneration`
/// so every field morphs to a checkmark for a second.
struct CopyLinkButton: View {
    var chrome: ToolbarChrome? = nil

    @Environment(BrowserModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmed = false
    @State private var resetTask: Task<Void, Never>?

    private var resolved: ToolbarChrome {
        chrome ?? ToolbarChrome.resolve(tint: model.selectedTab?.themeColor, colorScheme: colorScheme)
    }

    private var hasLink: Bool {
        guard let url = model.selectedTab?.url else { return false }
        return BrowserTab.isPageURL(url)
    }

    var body: some View {
        Button {
            model.copyCurrentLink()
        } label: {
            Image(systemName: confirmed ? "checkmark" : "link")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(resolved.fieldSymbol)
        .opacity(hasLink ? 1 : 0.35)
        .disabled(!hasLink)
        .help(confirmed ? "Copied" : "Copy Link")
        .accessibilityLabel(confirmed ? "Copied" : "Copy Link")
        .onChange(of: model.linkCopyGeneration) { _, _ in
            flash()
        }
    }

    private func flash() {
        resetTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            confirmed = true
        }
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                confirmed = false
            }
        }
    }
}
