import Foundation

/// Turns a folder, zip, xpi, or crx into an unpacked directory under `Extensions/<id>/`.
nonisolated enum ExtensionPackage {
    struct Prepared: Sendable {
        var id: String
        var directory: URL
        var manifest: ExtensionManifest
        var source: ExtensionSource
    }

    /// Copies or unpacks `source` into `root/<id>/`, replacing an existing folder with the same id.
    static func prepare(
        source: URL,
        into root: URL,
        sourceKind: ExtensionSource,
        preferredID: String?
    ) async throws -> Prepared {
        let capturedSource = source
        let capturedRoot = root
        return try await Task.detached(priority: .userInitiated) {
            try prepareSync(source: capturedSource, into: capturedRoot, sourceKind: sourceKind, preferredID: preferredID)
        }.value
    }

    private static func prepareSync(
        source: URL,
        into root: URL,
        sourceKind: ExtensionSource,
        preferredID: String?
    ) throws -> Prepared {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let scratch = fileManager.temporaryDirectory.appending(path: "myBrowser-extension-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        var crxID: String?
        let unpacked = scratch.appending(path: "unpacked", directoryHint: .isDirectory)
        switch sourceKind {
        case .folder:
            try copyFolder(source, to: unpacked)
        case .zip, .xpi:
            try unzip(source, to: unpacked)
        case .crx, .chromeWebStore:
            let payload = try crxZip(at: source)
            crxID = payload.extensionID
            if let preferredID, let crxID,
               ChromeWebStoreLink.isExtensionID(preferredID),
               ChromeWebStoreLink.isExtensionID(crxID),
               preferredID != crxID {
                throw ExtensionInstallError.store("The downloaded package is \(crxID), not the requested extension.")
            }
            let zipURL = scratch.appending(path: "extension.zip", directoryHint: .notDirectory)
            try payload.zip.write(to: zipURL)
            try unzip(zipURL, to: unpacked)
        }

        let loaded = try ExtensionManifest.load(from: unpacked)
        guard isInside(loaded.root, root: scratch) else {
            throw ExtensionInstallError.archive("The package tried to write outside its folder.")
        }
        let id = resolveID(manifest: loaded.manifest, crxID: crxID, preferredID: preferredID)
        let folder = root.appending(path: ExtensionManifest.directoryName(for: id), directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
            try fileManager.removeItem(at: folder)
        }
        try fileManager.moveItem(at: loaded.root, to: folder)
        try ExtensionWebKitCompat.apply(to: folder)
        OnePasswordPackage.apply(id: id, folder: folder)
        return Prepared(id: id, directory: folder, manifest: loaded.manifest, source: sourceKind)
    }

    static func sourceKind(for url: URL) -> ExtensionSource {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }
        switch url.pathExtension.lowercased() {
        case "xpi": return .xpi
        case "crx": return .crx
        case "zip": return .zip
        default: return .zip
        }
    }

    private static func resolveID(manifest: ExtensionManifest, crxID: String?, preferredID: String?) -> String {
        if let preferredID, ChromeWebStoreLink.isExtensionID(preferredID) { return preferredID }
        if let crxID, ChromeWebStoreLink.isExtensionID(crxID) { return crxID }
        if let key = manifest.publicKey {
            let derived = CRXArchive.extensionID(publicKey: key)
            if ChromeWebStoreLink.isExtensionID(derived) { return derived }
        }
        if let geckoID = manifest.geckoID, !geckoID.isEmpty { return geckoID }
        return ExtensionManifest.localID(for: manifest)
    }

    private static func crxZip(at url: URL) throws -> CRXArchive.Payload {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExtensionInstallError.archive("The file could not be read.")
        }
        if data.prefix(2).elementsEqual(Data("PK".utf8)) {
            return CRXArchive.Payload(version: 0, zip: data, extensionID: nil)
        }
        do {
            return try CRXArchive.payload(from: data)
        } catch let failure as CRXArchive.Failure {
            switch failure {
            case .notCRX:
                throw ExtensionInstallError.archive("This is not a Chrome extension package (CRX2 or CRX3).")
            case .truncated:
                throw ExtensionInstallError.archive("The Chrome extension package is incomplete.")
            case .unsupportedVersion(let version):
                throw ExtensionInstallError.archive("CRX version \(version) is not supported.")
            }
        }
    }

    private static func copyFolder(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ExtensionInstallError.archive("The folder could not be copied.")
        }
    }

    private static func unzip(_ archive: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path(percentEncoded: false), destination.path(percentEncoded: false)]
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ExtensionInstallError.archive("Couldn't run ditto to unpack the archive.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorText = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = errorText.isEmpty ? "" : " \(errorText)"
            throw ExtensionInstallError.archive("Unpacking failed.\(suffix)")
        }
    }

    /// Directory URLs often keep a trailing slash, so a raw prefix check against `root + "/"` misses children.
    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = directoryPath(root)
        let path = directoryPath(url)
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func directoryPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
