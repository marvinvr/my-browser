import AppKit
import Observation
import WebKit

/// One toolbar action. Rebuilt whenever the extension updates its icon, badge, or label.
struct ExtensionToolbarItem: Identifiable {
    var id: String
    var label: String
    var badge: String
    var isEnabled: Bool
    var image: NSImage?
}

/// App-level extension registry. One `WKWebExtensionController` per profile.
@Observable
final class ExtensionManager {
    let directory: URL
    let window = ExtensionWindow()

    private(set) var records: [ExtensionRecord] = []
    /// Bumped when an action's icon, badge, or label changes.
    private(set) var revision = 0
    private(set) var lastError: String?
    private(set) var isBusy = false

    @ObservationIgnored private let bridge = ExtensionControllerBridge()
    @ObservationIgnored private var controllers: [UUID: WKWebExtensionController] = [:]
    @ObservationIgnored private var contexts: [UUID: [String: WKWebExtensionContext]] = [:]
    @ObservationIgnored private var snapshots: [UUID: TabSnapshot] = [:]
    @ObservationIgnored private var openedTabs: Set<UUID> = []
    @ObservationIgnored private var announcedWindows: Set<UUID> = []
    @ObservationIgnored private var anchors: [String: AnchorBox] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var promptTail: Task<Bool, Never>?
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    @ObservationIgnored weak var model: BrowserModel?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            records = try ExtensionCatalogStore.load(from: directory)
        } catch {
            records = []
            lastError = "Couldn't read the extension list. The previous file was kept beside it."
        }
    }

    /// Call after this object is retained. A weak delegate pointer set inside `init` does not stick.
    func connectOwner() {
        bridge.manager = self
    }

    /// Binds the window model and loads extensions that are enabled for a profile.
    func attach(_ model: BrowserModel) {
        connectOwner()
        self.model = model
        window.model = model
        observeFocus()
        Task { await loadEnabled() }
    }

    func save() {
        do {
            try ExtensionCatalogStore.save(records, to: directory)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The profile's controller, created on first use so web views can reference it before any extension is loaded.
    func controller(for profileID: UUID) -> WKWebExtensionController {
        if let existing = controllers[profileID] { return existing }
        let configuration = WKWebExtensionController.Configuration(identifier: profileID)
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        configuration.defaultWebsiteDataStore = store
        configuration.webViewConfiguration.websiteDataStore = store
        configuration.webViewConfiguration.applicationNameForUserAgent = ProfileManager.safariApplicationName
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = bridge
        controllers[profileID] = controller
        return controller
    }

    func toolbarItems(profileID: UUID, tab: BrowserTab?) -> [ExtensionToolbarItem] {
        _ = revision
        guard let loaded = contexts[profileID] else { return [] }
        return records.compactMap { record in
            guard let context = loaded[record.id] else { return nil }
            guard let action = context.action(for: tab) ?? context.action(for: nil) else { return nil }
            let image = action.icon(for: CGSize(width: 32, height: 32)) ?? iconCache[record.id] ?? icon(for: record)
            return ExtensionToolbarItem(
                id: record.id,
                label: action.label.isEmpty ? record.name : action.label,
                badge: action.badgeText,
                isEnabled: action.isEnabled,
                image: image
            )
        }
    }

    func registerAnchor(_ view: NSView, for extensionID: String) {
        let box = anchors[extensionID] ?? AnchorBox()
        box.view = view
        anchors[extensionID] = box
    }

    func performAction(extensionID: String, profileID: UUID, tab: BrowserTab?) {
        contexts[profileID]?[extensionID]?.performAction(for: tab)
    }

    func presentPopup(for action: WKWebExtension.Action) {
        guard action.presentsPopup, let popover = action.popupPopover else { return }
        popover.behavior = .transient
        let identifier = action.webExtensionContext?.uniqueIdentifier
        if let identifier, let anchor = anchors[identifier]?.view, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            self.schedulePopupTag(popover)
            return
        }
        guard let content = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        let rect = NSRect(x: content.bounds.midX - 1, y: content.isFlipped ? 40 : content.bounds.height - 40, width: 2, height: 2)
        popover.show(relativeTo: rect, of: content, preferredEdge: .minY)
        schedulePopupTag(popover)
    }

    private func schedulePopupTag(_ popover: NSPopover) {
        tagPopup(popover)
        Task { @MainActor in
            self.tagPopup(popover)
        }
    }

    private func tagPopup(_ popover: NSPopover) {
        guard let window = popover.contentViewController?.view.window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("extension-popup")
        window.title = "Extension popup"
    }

    func icon(for record: ExtensionRecord) -> NSImage? {
        if let cached = iconCache[record.id] { return cached }
        let folder = directory.appending(path: record.directory, directoryHint: .isDirectory)
        guard let loaded = try? ExtensionManifest.load(from: folder),
              let relative = loaded.manifest.iconRelativePath else { return nil }
        let url = folder.appending(path: relative, directoryHint: .notDirectory).standardizedFileURL
        guard url.path(percentEncoded: false).hasPrefix(folder.standardizedFileURL.path(percentEncoded: false)),
              let image = NSImage(contentsOf: url) else { return nil }
        iconCache[record.id] = image
        return image
    }

    func clearError() { lastError = nil }

    // MARK: Install

    func install(from source: URL, kind: ExtensionSource? = nil, preferredID: String? = nil) async {
        let resolvedKind = kind ?? ExtensionPackage.sourceKind(for: source)
        await install(kind: resolvedKind, preferredID: preferredID) {
            try await ExtensionPackage.prepare(source: source, into: self.directory, sourceKind: resolvedKind, preferredID: preferredID)
        }
    }

    func installFromChromeWebStore(_ text: String) async {
        guard let id = ChromeWebStoreLink.extensionID(in: text) else {
            lastError = "Paste a Chrome Web Store link or a 32-character extension id."
            return
        }
        await install(kind: .chromeWebStore, preferredID: id) {
            let data = try await ChromeWebStoreLink.download(id: id)
            let file = FileManager.default.temporaryDirectory.appending(path: "\(id).crx", directoryHint: .notDirectory)
            try data.write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await ExtensionPackage.prepare(
                source: file,
                into: self.directory,
                sourceKind: .chromeWebStore,
                preferredID: id
            )
        }
    }

    func setEnabled(_ enabled: Bool, id: String, profileID: UUID) async {
        guard var record = records.first(where: { $0.id == id }) else { return }
        clearError()
        if enabled {
            if !record.enabledProfileIDs.contains(profileID) {
                record.enabledProfileIDs.append(profileID)
            }
            replace(record)
            do {
                try await load(record, profileID: profileID, reloadPages: true)
            } catch {
                var rolled = record
                rolled.enabledProfileIDs.removeAll { $0 == profileID }
                replace(rolled)
                lastError = error.localizedDescription
            }
        } else {
            unload(id: id, profileID: profileID)
            record.enabledProfileIDs.removeAll { $0 == profileID }
            replace(record)
        }
    }

    func remove(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        for profileID in record.enabledProfileIDs {
            unload(id: id, profileID: profileID)
        }
        let folder = directory.appending(path: record.directory, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        iconCache[id] = nil
        records.removeAll { $0.id == id }
        save()
    }

    /// Opens the options page with the extension's own web view configuration. Returns an error when there is nothing to open.
    @discardableResult
    func openOptionsPage(for context: WKWebExtensionContext) -> Error? {
        guard let model else { return ExtensionInstallError.webKit("No window is open.") }
        guard let url = context.optionsPageURL, let configuration = context.webViewConfiguration else {
            return ExtensionInstallError.webKit("This extension doesn't have an options page.")
        }
        guard model.presentPopup(configuration: configuration, url: url, spaceID: model.selectedSpaceID) != nil else {
            return ExtensionInstallError.webKit("Couldn't open the options page.")
        }
        return nil
    }

    func openOptions(id: String) {
        guard let profileID = model?.selectedSpace?.profileID, let context = contexts[profileID]?[id] else {
            lastError = "Enable the extension in this profile to open its options."
            return
        }
        if let error = openOptionsPage(for: context) {
            lastError = error.localizedDescription
        }
    }

    // MARK: Tab events

    func tabOpened(_ tab: BrowserTab) {
        guard openedTabs.insert(tab.id).inserted else { return }
        snapshots[tab.id] = snapshot(of: tab)
        let controller = controllers[tab.profileID] ?? controller(for: tab.profileID)
        announceWindow(profileID: tab.profileID, controller: controller)
        controller.didOpenTab(tab)
    }

    func tabClosed(_ tab: BrowserTab) {
        openedTabs.remove(tab.id)
        snapshots[tab.id] = nil
        guard let controller = controllers[tab.profileID] else { return }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        guard let controller = controllers[tab.profileID] else { return }
        controller.didActivateTab(tab, previousActiveTab: previous)
        revision &+= 1
    }

    func tabPropertiesChanged(_ tab: BrowserTab) {
        let next = snapshot(of: tab)
        let previous = snapshots[tab.id]
        snapshots[tab.id] = next
        guard let previous, let controller = controllers[tab.profileID] else { return }
        var properties: WKWebExtension.TabChangedProperties = []
        if previous.title != next.title { properties.insert(.title) }
        if previous.url != next.url { properties.insert(.URL) }
        if previous.isLoading != next.isLoading { properties.insert(.loading) }
        if previous.isPinned != next.isPinned { properties.insert(.pinned) }
        guard !properties.isEmpty else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func noteActionUpdated() {
        revision &+= 1
    }

    // MARK: Permissions

    func ask(_ request: PermissionPrompt.Request) async -> Bool {
        let previous = promptTail
        let next = Task { @MainActor in
            if let previous { _ = await previous.value }
            return await PermissionPrompt.confirm(request)
        }
        promptTail = next
        return await next.value
    }

    func remember(
        permissions: Set<WKWebExtension.Permission>,
        patterns: [String],
        granted: Bool,
        context: WKWebExtensionContext
    ) {
        guard let id = recordID(matching: context), var record = records.first(where: { $0.id == id }) else { return }
        let names = permissions.map(\.rawValue)
        if granted {
            record.grantedPermissions.append(contentsOf: names)
            record.deniedPermissions.removeAll { names.contains($0) }
            record.grantedMatchPatterns.append(contentsOf: patterns)
            record.deniedMatchPatterns.removeAll { patterns.contains($0) }
        } else {
            record.deniedPermissions.append(contentsOf: names)
            record.grantedPermissions.removeAll { names.contains($0) }
            record.deniedMatchPatterns.append(contentsOf: patterns)
            record.grantedMatchPatterns.removeAll { patterns.contains($0) }
        }
        replace(record)
    }

    // MARK: Private

    private func install(kind: ExtensionSource, preferredID: String?, prepare: () async throws -> ExtensionPackage.Prepared) async {
        clearError()
        isBusy = true
        defer { isBusy = false }
        if let preferredID, let existing = records.first(where: { $0.id == preferredID }) {
            for profileID in existing.enabledProfileIDs {
                unload(id: existing.id, profileID: profileID)
            }
        }
        do {
            let prepared = try await prepare()
            for profileID in records.first(where: { $0.id == prepared.id })?.enabledProfileIDs ?? [] {
                unload(id: prepared.id, profileID: profileID)
            }
            let ext = try await WKWebExtension(resourceBaseURL: prepared.directory)
            try Self.validate(ext)
            let name = ext.displayName ?? prepared.manifest.name
            let decision = await installDecision(name: name, extension: ext)
            var record = records.first(where: { $0.id == prepared.id }) ?? ExtensionRecord(
                id: prepared.id,
                name: name,
                version: ext.version ?? prepared.manifest.version,
                source: kind,
                directory: prepared.directory.lastPathComponent,
                enabledProfileIDs: [],
                grantedPermissions: [],
                deniedPermissions: [],
                grantedMatchPatterns: [],
                deniedMatchPatterns: [],
                hasOptionsPage: ext.hasOptionsPage || prepared.manifest.hasOptionsPage,
                summary: ext.displayDescription ?? prepared.manifest.summary
            )
            record.name = name
            record.version = ext.version ?? prepared.manifest.version
            record.source = kind
            record.directory = prepared.directory.lastPathComponent
            record.hasOptionsPage = ext.hasOptionsPage || prepared.manifest.hasOptionsPage
            record.summary = ext.displayDescription ?? prepared.manifest.summary
            record.grantedPermissions = decision.grantedPermissions
            record.deniedPermissions = decision.deniedPermissions
            record.grantedMatchPatterns = decision.grantedPatterns
            record.deniedMatchPatterns = decision.deniedPatterns
            if let profileID = model?.selectedSpace?.profileID, !record.enabledProfileIDs.contains(profileID) {
                record.enabledProfileIDs.append(profileID)
            }
            if let image = ext.icon(for: CGSize(width: 64, height: 64)) {
                iconCache[record.id] = image
            }
            replace(record)
            if let profileID = model?.selectedSpace?.profileID, record.isEnabled(in: profileID) {
                try await load(record, profileID: profileID, existing: ext, reloadPages: true)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func installDecision(name: String, extension ext: WKWebExtension) async -> PermissionDecision {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_EXTENSION_GRANT"] == "1" {
            return PermissionDecision(
                grantedPermissions: ext.requestedPermissions.map(\.rawValue).sorted(),
                deniedPermissions: [],
                grantedPatterns: ext.requestedPermissionMatchPatterns.map(\.string).sorted(),
                deniedPatterns: []
            )
        }
        #endif
        let request = PermissionPrompt.request(
            name: name,
            permissions: ext.requestedPermissions,
            patterns: ext.requestedPermissionMatchPatterns
        )
        let names = ext.requestedPermissions.map(\.rawValue).sorted()
        let patterns = ext.requestedPermissionMatchPatterns.map(\.string).sorted()
        guard !names.isEmpty || !patterns.isEmpty else {
            return PermissionDecision(grantedPermissions: [], deniedPermissions: [], grantedPatterns: [], deniedPatterns: [])
        }
        let allowed = await ask(request)
        if allowed {
            return PermissionDecision(grantedPermissions: names, deniedPermissions: [], grantedPatterns: patterns, deniedPatterns: [])
        }
        return PermissionDecision(grantedPermissions: [], deniedPermissions: names, grantedPatterns: [], deniedPatterns: patterns)
    }

    private func loadEnabled() async {
        for record in records {
            for profileID in record.enabledProfileIDs {
                do {
                    try await load(record, profileID: profileID)
                } catch {
                    if lastError == nil { lastError = error.localizedDescription }
                }
            }
        }
    }

    private func load(_ record: ExtensionRecord, profileID: UUID, existing: WKWebExtension? = nil, reloadPages: Bool = false) async throws {
        if contexts[profileID]?[record.id] != nil { return }
        let folder = directory.appending(path: record.directory, directoryHint: .isDirectory)
        let ext: WKWebExtension
        if let existing {
            ext = existing
        } else {
            ext = try await WKWebExtension(resourceBaseURL: folder)
            try Self.validate(ext)
        }
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = record.id
        context.inspectionName = record.name
        #if DEBUG
        context.isInspectable = true
        #endif
        apply(record, to: context)
        let controller = controller(for: profileID)
        announceWindow(profileID: profileID, controller: controller)
        do {
            try controller.load(context)
        } catch {
            throw ExtensionInstallError.webKit(error.localizedDescription)
        }
        var loaded = contexts[profileID] ?? [:]
        loaded[record.id] = context
        contexts[profileID] = loaded
        revision &+= 1
        if reloadPages, ext.hasInjectedContent {
            model?.reloadWebTabs(in: profileID)
        }
    }

    private func unload(id: String, profileID: UUID) {
        guard let context = contexts[profileID]?[id], let controller = controllers[profileID] else {
            contexts[profileID]?[id] = nil
            return
        }
        try? controller.unload(context)
        contexts[profileID]?[id] = nil
        revision &+= 1
    }

    private func apply(_ record: ExtensionRecord, to context: WKWebExtensionContext) {
        for name in record.grantedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: name))
        }
        for name in record.deniedPermissions where !record.grantedPermissions.contains(name) {
            context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: name))
        }
        for pattern in record.grantedMatchPatterns {
            guard let match = try? WKWebExtension.MatchPattern(string: pattern) else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: match)
        }
        for pattern in record.deniedMatchPatterns where !record.grantedMatchPatterns.contains(pattern) {
            guard let match = try? WKWebExtension.MatchPattern(string: pattern) else { continue }
            context.setPermissionStatus(.deniedExplicitly, for: match)
        }
    }

    private func announceWindow(profileID: UUID, controller: WKWebExtensionController) {
        guard announcedWindows.insert(profileID).inserted else { return }
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        guard let model else { return }
        for tab in model.tabs.values where tab.profileID == profileID && tab.isLoaded {
            guard openedTabs.insert(tab.id).inserted else { continue }
            snapshots[tab.id] = snapshot(of: tab)
            controller.didOpenTab(tab)
        }
    }

    private func snapshot(of tab: BrowserTab) -> TabSnapshot {
        let pinned = model?.library.item(tab.id)?.section != .tabs && model?.library.item(tab.id) != nil
        return TabSnapshot(title: tab.title, url: tab.url, isLoading: tab.isLoading, isPinned: pinned)
    }

    private func replace(_ record: ExtensionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    private func recordID(matching context: WKWebExtensionContext) -> String? {
        if let profileID = context.webExtensionController?.configuration.identifier,
           let match = contexts[profileID]?.first(where: { $0.value === context }) {
            return match.key
        }
        let identifier = context.uniqueIdentifier
        if records.contains(where: { $0.id == identifier }) { return identifier }
        return nil
    }

    private func observeFocus() {
        guard focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                guard let self, window === NSApp.mainWindow else { return }
                for controller in self.controllers.values {
                    controller.didFocusWindow(self.window)
                }
            }
        }
    }

    private static func validate(_ ext: WKWebExtension) throws {
        let version = Int(ext.manifestVersion)
        guard version == 2 || version == 3 else {
            let message = ext.errors.first?.localizedDescription ?? "The extension manifest could not be loaded."
            if version == 0 {
                throw ExtensionInstallError.webKit(message)
            }
            throw ExtensionInstallError.unsupportedManifest(version)
        }
        let fatal = ext.errors.contains { error in
            let code = (error as NSError).code
            return code == WKWebExtension.Error.invalidManifest.rawValue
                || code == WKWebExtension.Error.unsupportedManifestVersion.rawValue
                || code == WKWebExtension.Error.invalidArchive.rawValue
        }
        if fatal {
            throw ExtensionInstallError.webKit(ext.errors.map(\.localizedDescription).joined(separator: "\n"))
        }
    }

    #if DEBUG
    /// Writes a tiny MV3 extension and installs it into the current profile. Used by snapshot runs.
    func installDebugFixture(autoGrant: Bool) async {
        let root = directory.appending(path: "debug-fixture-src", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"Tint","version":"1.0.0","description":"Sample toolbar extension","action":{"default_title":"Tint","default_popup":"popup.html","default_icon":"icon.png"},"permissions":["storage"],"host_permissions":["https://*/*"]}
        """
        let popup = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font:13px -apple-system,sans-serif;margin:16px;width:260px}h1{font-size:14px;margin:0 0 6px}p{margin:0;color:#555}</style></head><body><h1>Tint</h1><p>Extension popup</p></body></html>
        """
        try? manifest.write(to: root.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try? popup.write(to: root.appending(path: "popup.html"), atomically: true, encoding: .utf8)
        try? Self.debugIconPNG().write(to: root.appending(path: "icon.png"))
        clearError()
        isBusy = true
        defer { isBusy = false }
        do {
            let prepared = try await ExtensionPackage.prepare(source: root, into: directory, sourceKind: .folder, preferredID: nil)
            let ext = try await WKWebExtension(resourceBaseURL: prepared.directory)
            try Self.validate(ext)
            let names = ext.requestedPermissions.map(\.rawValue)
            let patterns = ext.requestedPermissionMatchPatterns.map(\.string)
            let decision = autoGrant
                ? PermissionDecision(grantedPermissions: names, deniedPermissions: [], grantedPatterns: patterns, deniedPatterns: [])
                : await installDecision(name: ext.displayName ?? "Tint", extension: ext)
            var record = ExtensionRecord(
                id: prepared.id,
                name: ext.displayName ?? "Tint",
                version: ext.version ?? "1.0.0",
                source: .folder,
                directory: prepared.directory.lastPathComponent,
                enabledProfileIDs: [],
                grantedPermissions: decision.grantedPermissions,
                deniedPermissions: decision.deniedPermissions,
                grantedMatchPatterns: decision.grantedPatterns,
                deniedMatchPatterns: decision.deniedPatterns,
                hasOptionsPage: false,
                summary: "Sample toolbar extension"
            )
            if let profileID = model?.selectedSpace?.profileID {
                record.enabledProfileIDs = [profileID]
            }
            if let image = ext.icon(for: CGSize(width: 32, height: 32)) {
                iconCache[record.id] = image
            }
            replace(record)
            if let profileID = record.enabledProfileIDs.first {
                try await load(record, profileID: profileID, existing: ext)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showDebugPermissionPrompt() async {
        _ = await ask(PermissionPrompt.Request(
            extensionName: "Dark Reader",
            permissions: ["storage", "tabs"],
            matchPatterns: ["<all_urls>"]
        ))
    }

    func performDebugPopup() {
        guard let profileID = model?.selectedSpace?.profileID,
              let id = contexts[profileID]?.keys.first else { return }
        performAction(extensionID: id, profileID: profileID, tab: model?.selectedTab)
    }

    private static func debugIconPNG() -> Data {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 0.45, green: 0.28, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 7, yRadius: 7).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
    #endif
}

private struct PermissionDecision: Sendable {
    var grantedPermissions: [String]
    var deniedPermissions: [String]
    var grantedPatterns: [String]
    var deniedPatterns: [String]
}

private struct TabSnapshot: Equatable {
    var title: String
    var url: URL?
    var isLoading: Bool
    var isPinned: Bool
}

private final class AnchorBox {
    weak var view: NSView?
}
