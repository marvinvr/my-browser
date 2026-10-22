import Foundation

nonisolated enum ExtensionInstallError: LocalizedError, Equatable, Sendable {
    case noManifest
    case invalidManifest(String)
    case unsupportedManifest(Int)
    case archive(String)
    case store(String)
    case webKit(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noManifest:
            "This package doesn't contain a manifest.json."
        case .invalidManifest(let detail):
            "The manifest isn't valid. \(detail)"
        case .unsupportedManifest(let version):
            "Manifest version \(version) isn't supported. myBrowser loads Manifest V2 and V3 extensions."
        case .archive(let detail):
            "Couldn't unpack the extension. \(detail)"
        case .store(let detail):
            "Couldn't download the extension from the Chrome Web Store. \(detail)"
        case .webKit(let detail):
            detail
        case .cancelled:
            "The installation was cancelled."
        }
    }
}
