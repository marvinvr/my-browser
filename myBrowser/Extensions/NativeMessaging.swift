import Foundation
import os
import WebKit

nonisolated private let nativeMessagingLog = Logger(subsystem: "ch.marvinvr.mybrowser", category: "native-messaging")

/// Chromium and Firefox frame each message as a native-endian `UInt32` length plus UTF-8 JSON.
/// Message bodies are never logged.
nonisolated enum NativeMessageFraming {
    static let maximumBodyLength = 8 * 1024 * 1024

    static func frame(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw NativeMessagingError.invalidMessage
        }
        let body = try JSONSerialization.data(withJSONObject: object)
        guard body.count <= maximumBodyLength else { throw NativeMessagingError.messageTooLarge }
        var length = UInt32(body.count)
        var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        data.append(body)
        return data
    }

    /// Pulls every complete frame out of `buffer` and leaves the remainder in place.
    static func drain(_ buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= MemoryLayout<UInt32>.size {
            let length = buffer.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(as: UInt32.self)
            }
            let bodyLength = Int(length)
            guard bodyLength <= maximumBodyLength else { throw NativeMessagingError.messageTooLarge }
            let frameLength = MemoryLayout<UInt32>.size + bodyLength
            guard buffer.count >= frameLength else { break }
            let body = buffer.subdata(in: MemoryLayout<UInt32>.size..<frameLength)
            buffer.removeSubrange(0..<frameLength)
            frames.append(body)
        }
        return frames
    }
}

nonisolated enum NativeMessagingError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidMessage
    case messageTooLarge
    case hostNotFound(String)
    case originNotAllowed(String)
    case hostNotExecutable(String)
    case hostExited(String?)

    var description: String {
        switch self {
        case .invalidMessage: return "The native message was not a JSON object."
        case .messageTooLarge: return "The native message is too large."
        case .hostNotFound(let name): return "No native messaging host named \(name) is installed."
        case .originNotAllowed(let name): return "\(name) does not allow this extension."
        case .hostNotExecutable(let path): return "The native messaging host is not executable (\(path))."
        case .hostExited(let token):
            if let token { return "The native messaging host rejected the browser (\(token))." }
            return "The native messaging host exited."
        }
    }
}

/// A `NativeMessagingHosts/*.json` manifest. `path` is absolute.
nonisolated struct NativeMessagingManifest: Equatable, Sendable {
    var name: String
    var executablePath: String
    var allowedOrigins: [String]
    var allowedExtensions: [String]

    func permits(origin: String, extensionID: String) -> Bool {
        if allowedOrigins.contains(origin) { return true }
        if allowedExtensions.contains(extensionID) { return true }
        return false
    }
}

nonisolated enum NativeMessagingCatalog {
    static let onePasswordHostName = "com.1password.1password"
    /// Public Chrome Web Store ids 1Password ships in its host manifest. Not credentials.
    static let onePasswordExtensionOrigins = [
        "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/",
        "chrome-extension://hjlinigoblmkhjejkmbegnoaljkphmgo/",
        "chrome-extension://bkpbhnjcbehoklfkljkkbbmipaphipgl/",
        "chrome-extension://gejiddohjgogedgjnonbofjigllpkmbf/",
        "chrome-extension://khgocmkkpikpnmmkgmdnfckapcdkgfaf/",
        "chrome-extension://dppgmdbiimibapkepcbdbmkaabgiofem/",
    ]
    static let onePasswordExecutable = "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport"

    /// Directories Chromium browsers (and this app) read `NativeMessagingHosts` from.
    static var defaultSearchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let relative = [
            "myBrowser/NativeMessagingHosts",
            "Google/Chrome/NativeMessagingHosts",
            "Google/Chrome Beta/NativeMessagingHosts",
            "Google/Chrome Dev/NativeMessagingHosts",
            "Google/Chrome Canary/NativeMessagingHosts",
            "Arc/User Data/NativeMessagingHosts",
            "Microsoft Edge/NativeMessagingHosts",
            "Microsoft Edge Beta/NativeMessagingHosts",
            "Microsoft Edge Dev/NativeMessagingHosts",
            "Microsoft Edge Canary/NativeMessagingHosts",
            "BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Vivaldi/NativeMessagingHosts",
            "Chromium/NativeMessagingHosts",
            "Mozilla/NativeMessagingHosts",
        ]
        var directories = relative.map { support.appending(path: $0, directoryHint: .isDirectory) }
        directories.append(URL(fileURLWithPath: "/Library/Application Support/myBrowser/NativeMessagingHosts", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/Library/Application Support/Mozilla/NativeMessagingHosts", isDirectory: true))
        return directories
    }

    static func chromeOrigin(extensionID: String) -> String {
        "chrome-extension://\(extensionID)/"
    }

    /// Origin passed as the host's first argument. 1Password's allowlist is `chrome-extension://<id>/`.
    static func hostOrigin(extensionID: String, baseURL: URL?) -> String {
        if ChromeWebStoreLink.isExtensionID(extensionID) {
            return chromeOrigin(extensionID: extensionID)
        }
        if let baseURL, let scheme = baseURL.scheme, let host = baseURL.host, !scheme.isEmpty, !host.isEmpty {
            return "\(scheme)://\(host)/"
        }
        return "webkit-extension://\(extensionID)/"
    }

    static func locate(
        name: String,
        extensionID: String,
        origin: String,
        directories: [URL],
        allowWellKnownFallback: Bool = true
    ) -> Result<NativeMessagingManifest, NativeMessagingError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("..") else {
            return .failure(.hostNotFound(name))
        }
        var sawManifest = false
        for directory in directories {
            let url = directory.appending(path: "\(trimmed).json", directoryHint: .notDirectory)
            guard let manifest = load(url) else { continue }
            sawManifest = true
            if manifest.permits(origin: origin, extensionID: extensionID) {
                return .success(manifest)
            }
        }
        if allowWellKnownFallback, trimmed == onePasswordHostName, let fallback = onePasswordFallback() {
            if fallback.permits(origin: origin, extensionID: extensionID) {
                return .success(fallback)
            }
            return .failure(.originNotAllowed(trimmed))
        }
        if sawManifest { return .failure(.originNotAllowed(trimmed)) }
        return .failure(.hostNotFound(trimmed))
    }

    static func load(_ url: URL) -> NativeMessagingManifest? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawPath = (json["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, !rawPath.isEmpty else { return nil }
        let type = (json["type"] as? String) ?? "stdio"
        guard type == "stdio" else { return nil }
        let executable = resolveExecutable(rawPath, manifestURL: url)
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let origins = stringList(json["allowed_origins"])
        let extensions = stringList(json["allowed_extensions"])
        return NativeMessagingManifest(
            name: name,
            executablePath: executable,
            allowedOrigins: origins,
            allowedExtensions: extensions
        )
    }

    private static func resolveExecutable(_ path: String, manifestURL: URL) -> String {
        if path.hasPrefix("/") { return path }
        return manifestURL.deletingLastPathComponent().appending(path: path).standardizedFileURL.path
    }

    private static func stringList(_ value: Any?) -> [String] {
        guard let list = value as? [String] else { return [] }
        return list
    }

    private static func onePasswordFallback() -> NativeMessagingManifest? {
        guard FileManager.default.isExecutableFile(atPath: onePasswordExecutable) else { return nil }
        return NativeMessagingManifest(
            name: onePasswordHostName,
            executablePath: onePasswordExecutable,
            allowedOrigins: onePasswordExtensionOrigins,
            allowedExtensions: []
        )
    }
}

/// Public failure tokens the 1Password helper prints. Anything else on stderr is discarded.
nonisolated enum NativeMessagingHostDiagnostics {
    static let publicTokens = [
        "BrowserVerificationFailed",
        "BrowserSignatureInvalid",
        "InvalidBrowserSignature",
        "UnknownBrowser",
        "UnsupportedBrowser",
        "NotSigned",
        "hardened runtime",
        "parent browser was not valid",
        "approval list",
        "BrowserSupport was not part of the main browser's tree",
    ]

    static func token(in text: String) -> String? {
        let lower = text.lowercased()
        return publicTokens.first { lower.contains($0.lowercased()) }
    }
}

/// One stdio native-messaging process. The parent is this app, which is what 1Password's
/// code-signature check walks. Payloads stay in the pipes.
nonisolated final class NativeMessagingProcess: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var stderr = Data()
    private var stopped = false
    private var deliveredClose = false
    private let onFrame: @Sendable (Data) -> Void
    private let onClose: @Sendable (String?) -> Void

    private init(
        process: Process,
        input: FileHandle,
        output: FileHandle,
        errors: FileHandle,
        onFrame: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) {
        self.process = process
        self.input = input
        self.output = output
        self.errors = errors
        self.onFrame = onFrame
        self.onClose = onClose
    }

    static func start(
        executable: URL,
        origin: String,
        onFrame: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) throws -> NativeMessagingProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = [origin]
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let connection = NativeMessagingProcess(
            process: process,
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading,
            errors: errorPipe.fileHandleForReading,
            onFrame: onFrame,
            onClose: onClose
        )
        connection.output.readabilityHandler = { [weak connection] handle in
            connection?.consumeOutput(handle)
        }
        connection.errors.readabilityHandler = { [weak connection] handle in
            connection?.consumeError(handle)
        }
        try process.run()
        return connection
    }

    func send(_ object: Any) throws {
        let framed = try NativeMessageFraming.frame(object)
        lock.lock()
        let closed = stopped
        lock.unlock()
        if closed { throw NativeMessagingError.hostExited(nil) }
        try input.write(contentsOf: framed)
    }

    func stop() {
        finish(token: nil, terminate: true)
    }

    private func consumeOutput(_ handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            finish(token: nil, terminate: false)
            return
        }
        var frames: [Data] = []
        var failure: NativeMessagingError?
        lock.lock()
        buffer.append(chunk)
        do {
            frames = try NativeMessageFraming.drain(&buffer)
        } catch let error as NativeMessagingError {
            failure = error
        } catch {
            failure = .invalidMessage
        }
        lock.unlock()
        if let failure {
            nativeMessagingLog.error("Native message frame rejected: \(failure.description, privacy: .public)")
            finish(token: nil, terminate: true)
            return
        }
        for frame in frames {
            onFrame(frame)
        }
    }

    private func consumeError(_ handle: FileHandle) {
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lock.lock()
        if stderr.count < 4096 {
            stderr.append(chunk.prefix(4096 - stderr.count))
        }
        lock.unlock()
    }

    private func finish(token explicit: String?, terminate: Bool) {
        lock.lock()
        if deliveredClose {
            lock.unlock()
            return
        }
        deliveredClose = true
        stopped = true
        let captured = stderr
        lock.unlock()
        output.readabilityHandler = nil
        errors.readabilityHandler = nil
        try? input.close()
        if terminate, process.isRunning {
            process.terminate()
        }
        let text = String(data: captured, encoding: .utf8) ?? ""
        let token = explicit ?? NativeMessagingHostDiagnostics.token(in: text)
        if let token {
            nativeMessagingLog.error("Native host closed: \(token, privacy: .public)")
        }
        onClose(token)
    }
}

/// Holds a WebKit port so a background stdio callback can hop back to the main actor
/// without capturing the port in a `@Sendable` closure directly.
nonisolated private final class NativePortBox: @unchecked Sendable {
    nonisolated(unsafe) let port: WKWebExtension.MessagePort
    init(_ port: WKWebExtension.MessagePort) { self.port = port }
}

/// Delivers one host result. The callback stays on the stdio thread and receives `Data` only.
nonisolated private final class NativeReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let body: @Sendable (Result<Data, NativeMessagingError>) -> Void

    init(_ body: @escaping @Sendable (Result<Data, NativeMessagingError>) -> Void) {
        self.body = body
    }

    func succeed(_ data: Data) { fire(.success(data)) }

    func fail(_ error: NativeMessagingError) { fire(.failure(error)) }

    private func fire(_ result: Result<Data, NativeMessagingError>) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        guard first else { return }
        body(result)
    }
}

/// Bridges `runtime.connectNative` / `sendNativeMessage` to a stdio host.
/// One host process per port. The extension id is passed as a `chrome-extension://` origin.
@MainActor
final class NativeMessagingCenter {
    private var processes: [ObjectIdentifier: NativeMessagingProcess] = [:]
    private let directories: [URL]
    private let allowWellKnownFallback: Bool

    init(directories: [URL]? = nil, allowWellKnownFallback: Bool = true) {
        self.directories = directories ?? NativeMessagingCatalog.defaultSearchDirectories
        self.allowWellKnownFallback = allowWellKnownFallback
    }

    func connect(
        port: WKWebExtension.MessagePort,
        context: WKWebExtensionContext,
        completion: @escaping (Error?) -> Void
    ) {
        let name = port.applicationIdentifier ?? ""
        let origin = NativeMessagingCatalog.hostOrigin(extensionID: context.uniqueIdentifier, baseURL: context.baseURL)
        switch manifest(named: name, context: context, origin: origin) {
        case .failure(let error):
            nativeMessagingLog.error("connectNative \(name, privacy: .public) failed: \(error.description, privacy: .public)")
            port.disconnect(throwing: error)
            completion(error)
        case .success(let manifest):
            let key = ObjectIdentifier(port)
            let box = NativePortBox(port)
            do {
                let process = try NativeMessagingProcess.start(
                    executable: URL(fileURLWithPath: manifest.executablePath),
                    origin: origin,
                    onFrame: { data in
                        Task { @MainActor in
                            guard let object = try? JSONSerialization.jsonObject(with: data) else { return }
                            box.port.sendMessage(object, completionHandler: nil)
                        }
                    },
                    onClose: { token in
                        Task { @MainActor in
                            self.processes[key] = nil
                            if !box.port.isDisconnected {
                                box.port.disconnect(throwing: NativeMessagingError.hostExited(token))
                            }
                        }
                    }
                )
                processes[key] = process
                port.messageHandler = { [weak self] message, error in
                    if let error {
                        nativeMessagingLog.error("Native port closed: \(error.localizedDescription, privacy: .public)")
                        self?.processes[key]?.stop()
                        self?.processes[key] = nil
                        return
                    }
                    guard let message else { return }
                    do {
                        try self?.processes[key]?.send(message)
                    } catch {
                        nativeMessagingLog.error("Native port send failed: \(error.localizedDescription, privacy: .public)")
                        self?.processes[key]?.stop()
                        self?.processes[key] = nil
                        if !port.isDisconnected {
                            port.disconnect(throwing: error)
                        }
                    }
                }
                port.disconnectHandler = { [weak self] _ in
                    self?.processes[key]?.stop()
                    self?.processes[key] = nil
                }
                nativeMessagingLog.notice("Native host \(manifest.name, privacy: .public) started for \(origin, privacy: .public)")
                completion(nil)
            } catch {
                nativeMessagingLog.error("Native host \(manifest.name, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
                port.disconnect(throwing: error)
                completion(error)
            }
        }
    }

    func send(
        message: Any,
        identifier: String?,
        context: WKWebExtensionContext,
        reply: @escaping @Sendable (Result<Data, NativeMessagingError>) -> Void
    ) {
        let name = identifier ?? ""
        let origin = NativeMessagingCatalog.hostOrigin(extensionID: context.uniqueIdentifier, baseURL: context.baseURL)
        switch manifest(named: name, context: context, origin: origin) {
        case .failure(let error):
            nativeMessagingLog.error("sendNativeMessage \(name, privacy: .public) failed: \(error.description, privacy: .public)")
            reply(.failure(error))
        case .success(let manifest):
            let holder = NativeProcessHolder()
            let once = NativeReplyGate { result in
                holder.process?.stop()
                reply(result)
            }
            do {
                let process = try NativeMessagingProcess.start(
                    executable: URL(fileURLWithPath: manifest.executablePath),
                    origin: origin,
                    onFrame: { data in once.succeed(data) },
                    onClose: { token in once.fail(.hostExited(token)) }
                )
                holder.process = process
                try process.send(message)
            } catch {
                once.fail(.hostExited(nil))
            }
        }
    }

    func stopAll() {
        for process in processes.values {
            process.stop()
        }
        processes.removeAll()
    }

    private func manifest(
        named name: String,
        context: WKWebExtensionContext,
        origin: String
    ) -> Result<NativeMessagingManifest, NativeMessagingError> {
        NativeMessagingCatalog.locate(
            name: name,
            extensionID: context.uniqueIdentifier,
            origin: origin,
            directories: directories,
            allowWellKnownFallback: allowWellKnownFallback
        )
    }
}

nonisolated private final class NativeProcessHolder: @unchecked Sendable {
    var process: NativeMessagingProcess?
}
