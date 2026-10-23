import AppKit
import SwiftUI
import WebKit

/// Hosts the selected tab's web view. The web view is created once and moved between selections; it is never rebuilt just to show it again.
struct WebContentView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        ZStack {
            HostedWebView(
                tabID: model.selectedTab?.id,
                pictureInPictureTabID: model.pictureInPictureTabID,
                model: model
            )
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
    /// Kept in the hierarchy behind the selected page so the system PiP session survives a tab switch.
    var pictureInPictureTabID: UUID?
    var model: BrowserModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ container: NSView, context: Context) {
        let selected = webView(for: tabID)
        let backgroundID = pictureInPictureTabID == tabID ? nil : pictureInPictureTabID
        let background = webView(for: backgroundID)

        if let background {
            pin(background, in: container, atBack: true)
        }
        if let selected {
            pin(selected, in: container, atBack: false)
            if let tabID {
                model.tabs[tabID]?.restoreHistoryWhenWindowed()
            }
        }

        let keep: [NSView] = [background, selected].compactMap { $0 }
        for subview in container.subviews where !keep.contains(where: { $0 === subview }) {
            subview.removeFromSuperview()
        }
        context.coordinator.installedID = tabID
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func webView(for id: UUID?) -> WKWebView? {
        guard let id, let tab = model.tabs[id] else { return nil }
        tab.loadIfNeeded(using: model.profiles)
        return tab.webView
    }

    private func pin(_ webView: WKWebView, in container: NSView, atBack: Bool) {
        let needsConstraints = webView.superview !== container
        if needsConstraints {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
        }
        if atBack, let anchor = container.subviews.first(where: { $0 !== webView }) {
            container.addSubview(webView, positioned: .below, relativeTo: anchor)
        } else {
            container.addSubview(webView)
        }
        guard needsConstraints else { return }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    final class Coordinator {
        var installedID: UUID?
    }
}
