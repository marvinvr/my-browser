import WebKit

extension BrowserModel {
    /// Installed extensions in the current profile. Inspect Extension… lists these.
    var extensionInspectionTargets: [(id: String, name: String)] {
        guard let profileID = selectedSpace?.profileID else { return [] }
        return extensions?.inspectionTargets(in: profileID) ?? []
    }

    func showWebInspector() {
        guard let webView = focusedWebView() else { return }
        WebInspector.open(.inspector, on: webView)
        wantsDockedInspector = true
    }

    func showJavaScriptConsole() {
        guard let webView = focusedWebView() else { return }
        WebInspector.open(.console, on: webView)
        wantsDockedInspector = true
    }

    /// Sources tab of the inspector. `view-source:` is not a WKWebView navigation.
    func showPageSource() {
        guard let webView = focusedWebView() else { return }
        WebInspector.open(.sources, on: webView)
        wantsDockedInspector = true
    }

    func reloadIgnoringCache() {
        guard canReload else { return }
        selectedTab?.reloadFromOrigin()
    }

    func inspectExtension(id: String) {
        guard let profileID = selectedSpace?.profileID else { return }
        extensions?.inspectBackground(extensionID: id, profileID: profileID)
    }

    /// A docked inspector belongs to the focused pane. A detached one stays where it was opened.
    func noteInspectorFocus(from previous: BrowserTab?, to next: BrowserTab?) {
        guard wantsDockedInspector, let next, previous?.id != next.id else { return }
        let wasDocked = previous?.webView.map { WebInspector.isDocked($0) } ?? false
        guard wasDocked || dockMoveInFlight else {
            wantsDockedInspector = false
            return
        }
        if wasDocked, let old = previous?.webView {
            WebInspector.close(old)
        }
        dockMoveInFlight = true
        dockMoveGeneration &+= 1
        let generation = dockMoveGeneration
        let nextID = next.id
        Task { @MainActor in
            for _ in 0..<10 {
                if generation != self.dockMoveGeneration { return }
                if self.selectedTab?.id == nextID,
                   let webView = self.selectedTab?.webView,
                   webView.window != nil,
                   webView.bounds.width > 40 {
                    WebInspector.open(.inspector, on: webView)
                    self.dockMoveInFlight = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            if generation == self.dockMoveGeneration {
                self.dockMoveInFlight = false
            }
        }
    }

    private func focusedWebView() -> WKWebView? {
        guard let tab = selectedTab else { return nil }
        tab.loadIfNeeded(using: profiles)
        return tab.webView
    }
}
