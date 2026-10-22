import WebKit

/// `WKWebExtensionControllerDelegate` for every profile controller.
///
/// The controller holds this weakly. `ExtensionManager` owns it.
final class ExtensionControllerBridge: NSObject, WKWebExtensionControllerDelegate {
    weak var manager: ExtensionManager?

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        guard let window = manager?.window else { return [] }
        return [window]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        manager?.window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let manager, let model = manager.model else {
            completionHandler(nil, ExtensionInstallError.webKit("No window is open."))
            return
        }
        if configuration.shouldBePrivate {
            completionHandler(nil, ExtensionInstallError.webKit("Private windows aren't available."))
            return
        }
        if configuration.tabURLs.isEmpty {
            _ = model.openTabForExtension(url: nil, active: configuration.shouldBeFocused)
        } else {
            for url in configuration.tabURLs {
                _ = model.openTabForExtension(url: url, active: false)
            }
            if configuration.shouldBeFocused {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler(manager.window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let manager, let model = manager.model else {
            completionHandler(nil, ExtensionInstallError.webKit("No window is open."))
            return
        }
        let parent = configuration.parentTab as? BrowserTab
        if let url = configuration.url,
           controller.extensionContext(for: url) != nil,
           let webConfiguration = extensionContext.webViewConfiguration {
            _ = model.presentPopup(configuration: webConfiguration, url: url, spaceID: model.selectedSpaceID)
            if configuration.shouldBePinned, let tab = model.selectedTab {
                model.pin(tab.id)
            }
            completionHandler(model.selectedTab, nil)
            return
        }
        guard let tab = model.openTabForExtension(url: configuration.url, active: configuration.shouldBeActive || configuration.shouldBePinned, parent: parent) else {
            completionHandler(nil, ExtensionInstallError.webKit("Couldn't open a tab."))
            return
        }
        if configuration.shouldBePinned {
            model.pin(tab.id)
        }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let manager else {
            completionHandler(ExtensionInstallError.webKit("No window is open."))
            return
        }
        completionHandler(manager.openOptionsPage(for: extensionContext))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let request = PermissionPrompt.request(
            name: extensionContext.webExtension.displayName ?? "This extension",
            permissions: permissions,
            patterns: [WKWebExtension.MatchPattern]()
        )
        Task { @MainActor in
            let allowed = await self.manager?.ask(request) ?? false
            self.manager?.remember(permissions: permissions, patterns: [], granted: allowed, context: extensionContext)
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let patterns = urls.compactMap { Self.hostPattern(for: $0) }
        let request = PermissionPrompt.Request(
            extensionName: extensionContext.webExtension.displayName ?? "This extension",
            permissions: [],
            matchPatterns: patterns
        )
        Task { @MainActor in
            let allowed = await self.manager?.ask(request) ?? false
            self.manager?.remember(permissions: [], patterns: patterns, granted: allowed, context: extensionContext)
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let request = PermissionPrompt.request(
            name: extensionContext.webExtension.displayName ?? "This extension",
            permissions: [WKWebExtension.Permission](),
            patterns: matchPatterns
        )
        Task { @MainActor in
            let allowed = await self.manager?.ask(request) ?? false
            self.manager?.remember(permissions: [], patterns: matchPatterns.map(\.string), granted: allowed, context: extensionContext)
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext extensionContext: WKWebExtensionContext
    ) {
        manager?.noteActionUpdated()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        manager?.presentPopup(for: action)
        completionHandler(nil)
    }

    private static func hostPattern(for url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        let scheme = url.scheme ?? "*"
        return "\(scheme)://\(host)/*"
    }
}
