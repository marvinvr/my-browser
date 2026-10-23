import AuthenticationServices
import Foundation
import os
import Security

private let passkeyLog = Logger(subsystem: "ch.marvinvr.mybrowser", category: "passkeys")

/// User consent for platform passkeys, plus whether the browser entitlement is in this signature.
///
/// WebKit presents `navigator.credentials.create` / `get` itself. The sheet (iCloud Keychain,
/// the Passwords app, third-party providers, security keys) is shown only when the process
/// holds `com.apple.developer.web-browser.public-key-credential`. That entitlement is a managed
/// capability: it has to be on the Developer ID profile as well as in the signature.
@MainActor
@Observable
final class PasskeyBroker {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    enum Access: Equatable {
        case authorized
        case denied
        case notDetermined
        case unknown
    }

    private(set) var access: Access = .unknown
    private(set) var entitlementInSignature = false
    private(set) var deviceConfigured = false
    private(set) var statusDetail: String?

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var requestInFlight = false

    func refresh() {
        entitlementInSignature = Self.signatureContainsEntitlement
        if #available(macOS 26.2, *) {
            deviceConfigured = ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys
        } else {
            deviceConfigured = true
        }
        switch manager.authorizationStateForPlatformCredentials {
        case .authorized: access = .authorized
        case .denied: access = .denied
        case .notDetermined: access = .notDetermined
        @unknown default: access = .unknown
        }
    }

    /// Asks the system to let this browser use platform passkeys.
    /// Returns without calling the system when this signature has no passkey entitlement.
    func requestAccess() {
        refresh()
        guard entitlementInSignature else {
            statusDetail = "Apple has not granted the web-browser passkey entitlement for this build."
            return
        }
        guard !requestInFlight else { return }
        guard access != .authorized else { return }
        requestInFlight = true
        statusDetail = nil
        manager.requestAuthorizationForPublicKeyCredentials { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.requestInFlight = false
                switch state {
                case .authorized: self.access = .authorized
                case .denied: self.access = .denied
                case .notDetermined: self.access = .notDetermined
                @unknown default: self.access = .unknown
                }
                passkeyLog.notice("Passkey access is \(String(describing: self.access), privacy: .public)")
                if !self.entitlementInSignature {
                    self.statusDetail = "The system sheet also needs Apple's web-browser passkey entitlement."
                }
            }
        }
    }

    /// Once per launch, and only when the entitlement is already in the signature.
    /// Without it the system prompt cannot succeed, so a debug build does not ask.
    func requestAccessIfEntitled() {
        refresh()
        guard entitlementInSignature, access == .notDetermined, !requestInFlight else { return }
        requestAccess()
    }

    var statusLabel: String {
        switch access {
        case .authorized: "Allowed"
        case .denied: "Blocked"
        case .notDetermined: "Not allowed yet"
        case .unknown: "Unavailable"
        }
    }

    var footer: String {
        var lines = [
            "Each Space keeps its own cookies. Passkeys are filled by the system sheet in the tab that asked, from iCloud Keychain, the Passwords app, a credential provider such as 1Password, or a security key.",
        ]
        if !entitlementInSignature {
            lines.append("The sheet stays hidden until Apple grants \(Self.entitlement) and it is on the Developer ID profile.")
        } else if access == .denied {
            lines.append("Passkeys are blocked for myBrowser. Allow them to use the system sheet.")
        }
        if !deviceConfigured {
            lines.append("This Mac has no passkey provider turned on.")
        }
        if let statusDetail { lines.append(statusDetail) }
        return lines.joined(separator: " ")
    }

    /// `SecTask` reports the entitlement baked into the signature. A managed capability
    /// still needs the matching provisioning profile before WebKit will present the sheet.
    private static var signatureContainsEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
