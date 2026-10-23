import WebKit

extension BrowserTab {
    func installWebNotificationScript() {
        guard let webView, let notificationCenter else { return }
        let controller = webView.configuration.userContentController
        if !controller.userScripts.contains(where: { $0.source.contains(WebNotificationScript.marker) }) {
            controller.addUserScript(WKUserScript(
                source: WebNotificationScript.source(decisions: notificationCenter.store.decisions(for: profileID)),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            ))
        }
        controller.removeScriptMessageHandler(forName: WebNotificationScript.handlerName, contentWorld: .page)
        let relay = WebNotificationRelay()
        relay.tab = self
        notificationRelay = relay
        controller.addScriptMessageHandler(relay, contentWorld: .page, name: WebNotificationScript.handlerName)
    }

    func tearDownWebNotifications() {
        notificationCenter?.cancelRequests(tabID: id)
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: WebNotificationScript.handlerName,
            contentWorld: .page
        )
        notificationRelay?.tab = nil
        notificationRelay = nil
    }

    /// The embedded map can be stale after a settings change or a navigation. Show and request still ask native.
    func syncWebNotificationPermission() {
        guard let webView, let notificationCenter else { return }
        guard let current = webView.url ?? url, let origin = NotificationOrigin.key(for: current) else { return }
        let value = notificationCenter.store.decision(profileID: profileID, origin: origin)?.rawValue ?? "default"
        let script = WebNotificationScript.permissionUpdate(value)
        Task { _ = try? await webView.evaluateJavaScript(script) }
    }
}
