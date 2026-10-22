import Foundation

/// Chrome Web Store ids and the CRX download URL.
///
/// An id is 32 characters from `a` through `p`. Store links look like
/// `https://chromewebstore.google.com/detail/<name>/<id>`.
nonisolated enum ChromeWebStoreLink {
    private static let chromeVersion = "138.0.7204.100"

    static func isExtensionID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    /// A bare id, or the id embedded in a store URL.
    static func extensionID(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(trimmed) { return trimmed }
        guard let regex = try? NSRegularExpression(pattern: "(?<![a-p])[a-p]{32}(?![a-p])") else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let hit = Range(match.range, in: trimmed) else { return nil }
        return String(trimmed[hit])
    }

    /// `https://clients2.google.com/service/update2/crx?...&x=id%3D<id>%26uc`
    static func downloadURL(id: String, chromeVersion: String = chromeVersion) -> URL? {
        guard isExtensionID(id) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        components?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components?.url
    }

    /// Downloads the CRX. Google answers with a redirect to the package bytes.
    static func download(id: String) async throws -> Data {
        guard let url = downloadURL(id: id) else {
            throw ExtensionInstallError.store("That is not a Chrome Web Store extension id.")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ExtensionInstallError.store(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtensionInstallError.store("The store returned HTTP \(http.statusCode).")
        }
        guard data.count > 16 else {
            throw ExtensionInstallError.store("The store returned an empty download.")
        }
        if !data.prefix(4).elementsEqual(Data("Cr24".utf8)) {
            let preview = String(data: data.prefix(180), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = preview.isEmpty ? "" : " \(preview)"
            throw ExtensionInstallError.store("The store did not return an extension package.\(suffix)")
        }
        return data
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
}
