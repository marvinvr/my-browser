import AppKit

extension BrowserModel {
    /// A delivered notification was clicked or dismissed. A click focuses this window and the tab, then fires onclick.
    func revealWebNotification(spaceID: UUID, tabID: UUID, pageURL: URL?, kind: String, noteID: String, activate: Bool) {
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey && !$0.isSheet }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        if library.item(tabID) != nil {
            select(tabID)
        } else if library.space(spaceID) != nil, let pageURL {
            if selectedSpaceID != spaceID {
                selectSpace(spaceID)
            }
            openInNewTab(pageURL)
        }
        let script = WebNotificationScript.callbackScript(kind: kind, noteID: noteID)
        Task { @MainActor in
            for _ in 0..<12 {
                let webView = self.tabs[tabID]?.webView ?? self.selectedTab?.webView
                if let webView {
                    let value = try? await webView.evaluateJavaScript(script)
                    if value as? Bool == true || (value as? NSNumber)?.boolValue == true {
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }
}
