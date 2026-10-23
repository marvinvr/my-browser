import AppKit
import WebKit

/// Allow / Don't Allow sheet for an extension permission request.
enum PermissionPrompt {
    /// Keeps a fallback panel alive when no host window can present a sheet.
    private static var retainedPanel: NSAlert?

    struct Request: Sendable {
        var extensionName: String
        var permissions: [String]
        var matchPatterns: [String]
    }

    /// Presents the sheet on the key window, or as an app-modal alert when no window is up yet.
    @MainActor
    static func confirm(_ request: Request) async -> Bool {
        let lines = describe(request)
        guard !lines.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "\(request.extensionName) would like access"
            alert.informativeText = lines.joined(separator: "\n")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            alert.window.title = "Extension access"
            alert.window.identifier = NSUserInterfaceItemIdentifier("extension-permission")
            NSApp.activate(ignoringOtherApps: true)
            let host = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.canBecomeKey }
            if let host {
                host.makeKeyAndOrderFront(nil)
                alert.beginSheetModal(for: host) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
                let tag = {
                    let sheet = host.attachedSheet ?? alert.window
                    sheet.identifier = NSUserInterfaceItemIdentifier("extension-permission")
                    sheet.title = "Extension access"
                }
                tag()
                Task { @MainActor in tag() }
            } else {
                retainedPanel = alert
                alert.window.level = .floating
                alert.window.center()
                alert.window.makeKeyAndOrderFront(nil)
                continuation.resume(returning: false)
            }
        }
    }

    static func describe(_ request: Request) -> [String] {
        var lines: [String] = []
        for permission in request.permissions.sorted() {
            lines.append("• \(permissionLabel(permission))")
        }
        for pattern in request.matchPatterns.sorted() {
            lines.append("• \(patternLabel(pattern))")
        }
        if lines.count > 12 {
            let extra = lines.count - 12
            lines = Array(lines.prefix(12))
            lines.append("• and \(extra) more")
        }
        return lines
    }

    static func permissionLabel(_ permission: String) -> String {
        switch permission {
        case "activeTab": "Access the current tab when you click the extension"
        case "alarms": "Schedule alarms"
        case "clipboardWrite": "Write to the clipboard"
        case "contextMenus", "menus": "Add items to menus"
        case "cookies": "Read and change cookies"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess": "Block or change network requests"
        case "declarativeNetRequestFeedback": "See which network rules matched"
        case "nativeMessaging": "Connect to apps on this Mac, such as 1Password"
        case "notifications": "Show notifications"
        case "scripting": "Run scripts on pages you allow"
        case "storage": "Store data on this Mac"
        case "tabs": "See the titles and addresses of your tabs"
        case "unlimitedStorage": "Store more data on this Mac"
        case "webNavigation": "See navigation events"
        case "webRequest": "See network requests"
        default: permission
        }
    }

    static func patternLabel(_ pattern: String) -> String {
        switch pattern {
        case "<all_urls>", "*://*/*", "http://*/*", "https://*/*":
            return "Read and change data on all websites"
        default:
            return "Read and change data on \(pattern)"
        }
    }

    static func request(name: String, permissions: some Sequence<WKWebExtension.Permission>, patterns: some Sequence<WKWebExtension.MatchPattern>) -> Request {
        Request(
            extensionName: name,
            permissions: permissions.map(\.rawValue),
            matchPatterns: patterns.map(\.string)
        )
    }
}
