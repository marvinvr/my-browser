import AppKit
import SwiftUI

/// Hosts the focused pane (`selectedTab`). Side-by-side layout reads `BrowserModel.displayedContent`.
/// Phase 1 shows that one web view. The web view is created once and moved between selections; it is never rebuilt just to show it again.
struct WebContentView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        ZStack {
            HostedWebView(tabID: model.selectedTab?.id, model: model)
            if model.selectedTab == nil {
                emptyState
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.selectedTab == nil)
        .background {
            NavigationSwipeMonitor(
                canGoBack: model.selectedTab?.canGoBack ?? false,
                canGoForward: model.selectedTab?.canGoForward ?? false
            )
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

private struct HostedWebView: NSViewRepresentable {
    var tabID: UUID?
    var model: BrowserModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let tabID, let tab = model.tabs[tabID] else {
            clear(container, context: context)
            return
        }
        tab.loadIfNeeded(using: model.profiles)
        guard let webView = tab.webView else {
            clear(container, context: context)
            return
        }
        if context.coordinator.installedID == tabID, webView.superview === container {
            tab.restoreHistoryWhenWindowed()
            return
        }
        for subview in container.subviews where subview !== webView {
            subview.removeFromSuperview()
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        context.coordinator.installedID = tabID
        tab.restoreHistoryWhenWindowed()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func clear(_ container: NSView, context: Context) {
        context.coordinator.installedID = nil
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    final class Coordinator {
        var installedID: UUID?
    }
}
