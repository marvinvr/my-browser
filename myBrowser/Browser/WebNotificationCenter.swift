import AppKit
import Observation
import UserNotifications
import WebKit

struct NotificationPrompt: Identifiable, Equatable {
    var id: UUID
    var host: String
    var origin: String
    var tabID: UUID?
}

/// Page Notification API bridge. One store per library, one prompt at a time.
@Observable
final class WebNotificationCenter {
    let store: NotificationPermissionStore
    private(set) var prompt: NotificationPrompt?
    weak var model: BrowserModel?

    @ObservationIgnored private let bridge = WebNotificationBridge()
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var pending: PermissionAsk?
    @ObservationIgnored private var queue: [PermissionAsk] = []

    init(directory: URL?) {
        store = NotificationPermissionStore(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        session = URLSession(configuration: configuration)
        bridge.owner = self
    }

    /// System notifications can arrive before the first window, so the delegate is set at launch.
    func start() {
        bridge.owner = self
        UNUserNotificationCenter.current().delegate = bridge
    }

    #if DEBUG
    func applyDebugFixtures() {
        let env = ProcessInfo.processInfo.environment
        if env["MYBROWSER_DEBUG_NOTIFICATION_PROMPT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.showDebugPrompt()
            }
        }
        if env["MYBROWSER_DEBUG_NOTIFICATION_POST"] == "1" {
            Task { await self.postDebugSample() }
        }
    }

    private func showDebugPrompt() {
        guard pending == nil else { return }
        let profile = model?.selectedSpace?.profileID ?? model?.selectedSpaceID ?? UUID()
        let ask = PermissionAsk(
            origin: "https://mail.google.com",
            host: "mail.google.com",
            profileID: profile,
            tabID: model?.selectedTab?.id,
            continuation: nil
        )
        present(ask)
    }

    private func postDebugSample() async {
        guard let model else { return }
        try? await Task.sleep(for: .milliseconds(900))
        let profile = model.selectedSpace?.profileID ?? model.selectedSpaceID
        let origin = "https://example.com"
        store.set(profileID: profile, origin: origin, decision: .granted)
        _ = await authorizeSystemIfNeeded()
        let tabID = model.selectedTab?.id ?? UUID()
        let page = model.selectedTab?.url?.absoluteString ?? "https://example.com/"
        _ = await deliver(
            site: "example.com",
            title: "New message",
            body: "Page notifications are on.",
            silent: false,
            icon: model.selectedTab?.favicon ?? URL(string: "https://example.com/").flatMap { model.favicons.cachedFavicon(for: $0) },
            identifier: NotificationOrigin.systemIdentifier(profileID: profile, origin: origin, tag: "debug", noteID: "debug"),
            userInfo: WebNotificationPayload(
                profileID: profile,
                spaceID: model.selectedSpaceID,
                tabID: tabID,
                origin: origin,
                noteID: "debug",
                pageURL: page,
                silent: false
            ).userInfo
        )
    }
    #endif

    func handle(_ message: WebNotificationMessage, tab: BrowserTab) async -> [String: Any] {
        switch message.kind {
        case "query":
            return ["permission": permissionString(profileID: tab.profileID, origin: message.origin)]
        case "request":
            return ["permission": await request(message, tab: tab)]
        case "show":
            return ["ok": await show(message, tab: tab)]
        case "close":
            close(message, tab: tab)
            return ["ok": true]
        default:
            return ["ok": false, "permission": "denied"]
        }
    }

    func choose(allow: Bool) {
        guard let ask = pending, !ask.finished else { return }
        ask.finished = true
        let continuation = ask.continuation
        ask.continuation = nil
        pending = nil
        prompt = nil
        Task {
            let value = await self.record(allow: allow, profileID: ask.profileID, origin: ask.origin)
            continuation?.resume(returning: value)
            self.showNext()
        }
    }

    func setSiteChoice(profileID: UUID, origin: String, choice: NotificationSiteChoice) {
        Task { await self.applyChoice(profileID: profileID, origin: origin, choice: choice) }
    }

    func siteChoice(profileID: UUID, origin: String) -> NotificationSiteChoice {
        switch store.decision(profileID: profileID, origin: origin) {
        case .granted: .allow
        case .denied: .block
        case nil: .ask
        }
    }

    func cancelRequests(tabID: UUID) {
        if let ask = pending, ask.tabID == tabID {
            finish(ask, value: "default")
        }
        let waiting = queue.filter { $0.tabID == tabID }
        queue.removeAll { $0.tabID == tabID }
        for ask in waiting where !ask.finished {
            ask.finished = true
            ask.continuation?.resume(returning: "default")
            ask.continuation = nil
        }
    }

    func handleResponse(payload: WebNotificationPayload, action: String) {
        guard payload.kind == "web" else { return }
        guard action == UNNotificationDefaultActionIdentifier || action == UNNotificationDismissActionIdentifier else {
            return
        }
        let click = action == UNNotificationDefaultActionIdentifier
        model?.revealWebNotification(
            spaceID: payload.spaceID,
            tabID: payload.tabID,
            pageURL: URL(string: payload.pageURL).flatMap { BrowserTab.isPageURL($0) ? $0 : nil },
            kind: click ? "click" : "close",
            noteID: payload.noteID,
            activate: click
        )
    }

    private func permissionString(profileID: UUID, origin: String?) -> String {
        guard let origin else { return "denied" }
        return store.decision(profileID: profileID, origin: origin)?.rawValue ?? "default"
    }

    private func request(_ message: WebNotificationMessage, tab: BrowserTab) async -> String {
        guard let origin = message.origin else { return "denied" }
        if let decision = store.decision(profileID: tab.profileID, origin: origin) {
            return decision.rawValue
        }
        guard message.gesture else { return "default" }
        return await withCheckedContinuation { continuation in
            let ask = PermissionAsk(
                origin: origin,
                host: NotificationOrigin.displayHost(origin),
                profileID: tab.profileID,
                tabID: tab.id,
                continuation: continuation
            )
            if pending == nil {
                present(ask)
            } else {
                queue.append(ask)
            }
        }
    }

    private func show(_ message: WebNotificationMessage, tab: BrowserTab) async -> Bool {
        guard let origin = message.origin else {
            trace("show missing origin")
            return false
        }
        let decision = store.decision(profileID: tab.profileID, origin: origin)
        guard decision == .granted else {
            trace("show \(origin) decision \(decision?.rawValue ?? "none") profile \(tab.profileID.uuidString)")
            return false
        }
        guard let spaceID = model?.library.item(tab.id)?.spaceID ?? model?.selectedSpaceID else {
            trace("show no space")
            return false
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        trace("show auth \(settings.authorizationStatus.rawValue) origin \(origin)")
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else { return false }
        let icon = await icon(message: message, pageURL: tab.url)
        let noteID = message.noteID.isEmpty ? UUID().uuidString : message.noteID
        let payload = WebNotificationPayload(
            profileID: tab.profileID,
            spaceID: spaceID,
            tabID: tab.id,
            origin: origin,
            noteID: noteID,
            pageURL: tab.url?.absoluteString ?? origin,
            silent: message.silent
        )
        return await deliver(
            site: NotificationOrigin.displayHost(origin),
            title: message.title,
            body: message.body,
            silent: message.silent,
            icon: icon,
            identifier: NotificationOrigin.systemIdentifier(
                profileID: tab.profileID,
                origin: origin,
                tag: message.tag,
                noteID: noteID
            ),
            userInfo: payload.userInfo
        )
    }

    private func close(_ message: WebNotificationMessage, tab: BrowserTab) {
        guard let origin = message.origin else { return }
        let identifier = NotificationOrigin.systemIdentifier(
            profileID: tab.profileID,
            origin: origin,
            tag: message.tag,
            noteID: message.noteID
        )
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func icon(message: WebNotificationMessage, pageURL: URL?) async -> NSImage? {
        if let pageURL, let cached = model?.favicons.cachedFavicon(for: pageURL) {
            return cached
        }
        guard let url = URL(string: message.icon),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    private func deliver(
        site: String,
        title: String,
        body: String,
        silent: Bool,
        icon: NSImage?,
        identifier: String,
        userInfo: [String: Any]
    ) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = clip(site, 120)
        if !title.isEmpty { content.subtitle = clip(title, 180) }
        content.body = clip(body, 500)
        content.threadIdentifier = site
        content.userInfo = userInfo
        if !silent { content.sound = .default }
        if let icon, let attachment = attachment(image: icon) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        do {
            try await center.add(request)
            await writeDebugEvidence(identifier: identifier, content: content)
            return true
        } catch {
            trace("add failed \(error.localizedDescription)")
            return false
        }
    }

    private func trace(_ line: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"] != nil else { return }
        let url = URL(fileURLWithPath: "/tmp/mybrowser-notification-trace.txt")
        let text = line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        #endif
    }

    private func attachment(image: NSImage) -> UNNotificationAttachment? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "myBrowser-notifications", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: "icon", url: url, options: nil)
        } catch {
            return nil
        }
    }

    private func writeDebugEvidence(identifier: String, content: UNNotificationContent) async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"] != nil else { return }
        try? await Task.sleep(for: .milliseconds(400))
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        let settings = await center.notificationSettings()
        func row(_ id: String, _ title: String, _ subtitle: String, _ body: String) -> [String: String] {
            ["id": id, "title": title, "subtitle": subtitle, "body": body]
        }
        let payload: [String: Any] = [
            "authorization": settings.authorizationStatus.rawValue,
            "posted": row(identifier, content.title, content.subtitle, content.body),
            "delivered": delivered.map { row($0.request.identifier, $0.request.content.title, $0.request.content.subtitle, $0.request.content.body) },
            "pending": pending.map { row($0.identifier, $0.content.title, $0.content.subtitle, $0.content.body) }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp/mybrowser-delivered-notifications.json"), options: .atomic)
        #endif
    }

    private func record(allow: Bool, profileID: UUID, origin: String) async -> String {
        if allow {
            _ = await authorizeSystemIfNeeded()
            store.set(profileID: profileID, origin: origin, decision: .granted)
            publish(origin: origin, profileID: profileID)
            return "granted"
        }
        store.set(profileID: profileID, origin: origin, decision: .denied)
        publish(origin: origin, profileID: profileID)
        return "denied"
    }

    private func applyChoice(profileID: UUID, origin: String, choice: NotificationSiteChoice) async {
        let value: String
        switch choice {
        case .allow:
            _ = await authorizeSystemIfNeeded()
            store.set(profileID: profileID, origin: origin, decision: .granted)
            value = "granted"
        case .block:
            store.set(profileID: profileID, origin: origin, decision: .denied)
            value = "denied"
        case .ask:
            store.remove(profileID: profileID, origin: origin)
            value = "default"
        }
        publish(origin: origin, profileID: profileID)
        resolvePending(origin: origin, profileID: profileID, value: value)
    }

    /// The first Allow asks macOS. Later Allows do not show the system dialog again.
    private func authorizeSystemIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    private func publish(origin: String, profileID: UUID) {
        let value = store.decision(profileID: profileID, origin: origin)?.rawValue ?? "default"
        let script = WebNotificationScript.permissionUpdate(value)
        guard let model else { return }
        for tab in model.tabs.values where tab.profileID == profileID {
            guard let url = tab.url, NotificationOrigin.key(for: url) == origin, let webView = tab.webView else { continue }
            Task { _ = try? await webView.evaluateJavaScript(script) }
        }
    }

    private func present(_ ask: PermissionAsk) {
        pending = ask
        prompt = NotificationPrompt(id: ask.id, host: ask.host, origin: ask.origin, tabID: ask.tabID)
    }

    private func resolvePending(origin: String, profileID: UUID, value: String) {
        if let ask = pending, ask.origin == origin, ask.profileID == profileID {
            finish(ask, value: value)
        }
        let waiting = queue.filter { $0.origin == origin && $0.profileID == profileID }
        queue.removeAll { $0.origin == origin && $0.profileID == profileID }
        for ask in waiting where !ask.finished {
            ask.finished = true
            ask.continuation?.resume(returning: value)
            ask.continuation = nil
        }
    }

    private func finish(_ ask: PermissionAsk, value: String) {
        guard !ask.finished else { return }
        ask.finished = true
        let continuation = ask.continuation
        ask.continuation = nil
        if pending === ask {
            pending = nil
            prompt = nil
        }
        continuation?.resume(returning: value)
        showNext()
    }

    private func showNext() {
        guard pending == nil else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if !next.finished {
                present(next)
                return
            }
        }
    }

    private func clip(_ value: String, _ limit: Int) -> String {
        if value.count <= limit { return value }
        return String(value.prefix(limit))
    }
}

private final class PermissionAsk {
    let id = UUID()
    let origin: String
    let host: String
    let profileID: UUID
    let tabID: UUID?
    var continuation: CheckedContinuation<String, Never>?
    var finished = false

    init(
        origin: String,
        host: String,
        profileID: UUID,
        tabID: UUID?,
        continuation: CheckedContinuation<String, Never>?
    ) {
        self.origin = origin
        self.host = host
        self.profileID = profileID
        self.tabID = tabID
        self.continuation = continuation
    }
}

struct WebNotificationPayload: Sendable {
    var kind: String = "web"
    var profileID: UUID
    var spaceID: UUID
    var tabID: UUID
    var origin: String
    var noteID: String
    var pageURL: String
    var silent: Bool

    var userInfo: [String: Any] {
        [
            "mb.kind": kind,
            "mb.profile": profileID.uuidString,
            "mb.space": spaceID.uuidString,
            "mb.tab": tabID.uuidString,
            "mb.origin": origin,
            "mb.note": noteID,
            "mb.url": pageURL,
            "mb.silent": silent
        ]
    }

    init(profileID: UUID, spaceID: UUID, tabID: UUID, origin: String, noteID: String, pageURL: String, silent: Bool) {
        self.profileID = profileID
        self.spaceID = spaceID
        self.tabID = tabID
        self.origin = origin
        self.noteID = noteID
        self.pageURL = pageURL
        self.silent = silent
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard (userInfo["mb.kind"] as? String) == "web",
              let profile = (userInfo["mb.profile"] as? String).flatMap(UUID.init(uuidString:)),
              let space = (userInfo["mb.space"] as? String).flatMap(UUID.init(uuidString:)),
              let tab = (userInfo["mb.tab"] as? String).flatMap(UUID.init(uuidString:)),
              let origin = userInfo["mb.origin"] as? String else { return nil }
        profileID = profile
        spaceID = space
        tabID = tab
        self.origin = origin
        noteID = userInfo["mb.note"] as? String ?? ""
        pageURL = userInfo["mb.url"] as? String ?? ""
        if let silent = userInfo["mb.silent"] as? Bool {
            self.silent = silent
        } else if let silent = userInfo["mb.silent"] as? NSNumber {
            self.silent = silent.boolValue
        } else {
            silent = false
        }
    }
}

struct WebNotificationMessage: Sendable {
    var kind: String
    var origin: String?
    var noteID: String
    var title: String
    var body: String
    var icon: String
    var tag: String
    var silent: Bool
    var gesture: Bool

    static func parse(_ message: WKScriptMessage) -> WebNotificationMessage {
        let body = message.body as? [String: Any] ?? [:]
        let frame = message.frameInfo
        let origin = NotificationOrigin.key(
            scheme: frame.securityOrigin.`protocol`,
            host: frame.securityOrigin.host,
            port: frame.securityOrigin.port
        )
        return WebNotificationMessage(
            kind: string(body["kind"], limit: 20),
            origin: origin,
            noteID: string(body["id"], limit: 80),
            title: string(body["title"], limit: 180),
            body: string(body["body"], limit: 500),
            icon: string(body["icon"], limit: 2000),
            tag: string(body["tag"], limit: 120),
            silent: bool(body["silent"]),
            gesture: bool(body["gesture"])
        )
    }

    private static func string(_ value: Any?, limit: Int) -> String {
        guard let raw = value as? String else { return "" }
        if raw.count <= limit { return raw }
        return String(raw.prefix(limit))
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }
}

/// Retained by the web view's user content controller. Forwards into the shared center.
final class WebNotificationRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: BrowserTab?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        let parsed = WebNotificationMessage.parse(message)
        guard let tab, let center = tab.notificationCenter else {
            return (["ok": false, "permission": "denied"], nil)
        }
        let reply = await center.handle(parsed, tab: tab)
        return (reply, nil)
    }
}

final class WebNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    weak var owner: WebNotificationCenter?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let silent = (notification.request.content.userInfo["mb.silent"] as? Bool)
            ?? (notification.request.content.userInfo["mb.silent"] as? NSNumber)?.boolValue
            ?? false
        return silent ? [.banner, .list] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        guard (info["mb.kind"] as? String) == "web",
              let profileID = (info["mb.profile"] as? String).flatMap(UUID.init(uuidString:)),
              let spaceID = (info["mb.space"] as? String).flatMap(UUID.init(uuidString:)),
              let tabID = (info["mb.tab"] as? String).flatMap(UUID.init(uuidString:)),
              let origin = info["mb.origin"] as? String else { return }
        let noteID = info["mb.note"] as? String ?? ""
        let pageURL = info["mb.url"] as? String ?? ""
        let silent = (info["mb.silent"] as? Bool) ?? (info["mb.silent"] as? NSNumber)?.boolValue ?? false
        await MainActor.run {
            let payload = WebNotificationPayload(
                profileID: profileID,
                spaceID: spaceID,
                tabID: tabID,
                origin: origin,
                noteID: noteID,
                pageURL: pageURL,
                silent: silent
            )
            self.owner?.handleResponse(payload: payload, action: action)
        }
    }
}
