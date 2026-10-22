import Foundation

/// Turns what the user typed into the command bar into a URL to load.
///
/// Trimmed input with an explicit scheme (`http`, `https`, `file`, `about`, `data`, `mailto`, …)
/// is a URL. `localhost`, an IPv4 address, or a bracketed IPv6 address (each with an optional port
/// and path) becomes an `http` URL. `host.tld` with no spaces, whose last label is at least two
/// letters or a known suffix, becomes an `https` URL. Anything with spaces, or a single word
/// without a dot, is a search.
nonisolated enum URLInput {
    enum Resolution: Equatable, Sendable {
        case url(URL)
        case search(String)
    }

    /// URL if the input looks like one, otherwise a search query (already trimmed).
    static func resolve(_ input: String) -> Resolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .search("") }

        if trimmed.contains(where: \.isWhitespace) {
            return .search(trimmed)
        }
        if trimmed.hasPrefix("?") || trimmed.hasPrefix("#") {
            return .search(trimmed)
        }
        if let scheme = schemePrefix(trimmed) {
            if let url = url(forExplicitScheme: scheme.scheme, original: trimmed) {
                return .url(url)
            }
            return .search(trimmed)
        }
        if let url = implicitURL(trimmed) {
            return .url(url)
        }
        return .search(trimmed)
    }

    static func url(for input: String, engine: SearchEngine = .current) -> URL {
        switch resolve(input) {
        case .url(let url): url
        case .search(let query): engine.searchURL(for: query)
        }
    }

    // MARK: - Explicit schemes

    private static let knownSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "mailto",
        "ftp", "ftps", "ws", "wss", "javascript", "blob"
    ]

    /// Schemes that are only real URLs when written with `://`.
    private static let hierarchicalSchemes: Set<String> = [
        "http", "https", "file", "ftp", "ftps", "ws", "wss"
    ]

    /// A scheme we are willing to navigate to, or nil when the colon is a port (`localhost:3000`).
    private static func schemePrefix(_ text: String) -> (scheme: String, rest: Substring)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let raw = text[..<colon]
        guard isSchemeToken(raw) else { return nil }
        let scheme = raw.lowercased()
        let rest = text[text.index(after: colon)...]
        let recognized = knownSchemes.contains(scheme) || rest.hasPrefix("//")
        guard recognized else { return nil }
        if hierarchicalSchemes.contains(scheme), !rest.hasPrefix("//") { return nil }
        return (scheme, rest)
    }

    private static func isSchemeToken(_ raw: Substring) -> Bool {
        guard let first = raw.first, first.isASCII && first.isLetter else { return false }
        return raw.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "+" || character == "-" || character == ".")
        }
    }

    private static func url(forExplicitScheme scheme: String, original: String) -> URL? {
        guard var components = URLComponents(string: original) else {
            return URL(string: original, encodingInvalidCharacters: true)
        }
        components.scheme = scheme
        if var host = components.host, !host.isEmpty {
            let originalHost = host
            while host.hasSuffix(".") { host.removeLast() }
            // Bracketed IPv6 hosts (`[::1]`) are already in URL form; don't case-fold them.
            if !host.hasPrefix("["), !host.contains(":") {
                host = host.lowercased()
            }
            if host != originalHost, !host.isEmpty {
                components.host = host
            }
        }
        return components.url
    }

    // MARK: - Host-like input (no scheme)

    private struct Authority {
        var usesHTTP: Bool
        var host: String
        var port: Int?
        var isIPv6: Bool
    }

    private static func implicitURL(_ text: String) -> URL? {
        let (authority, remainder) = splitAuthority(text)
        guard let parsed = parseAuthority(authority) else { return nil }
        guard remainder.isEmpty || remainder.hasPrefix("/") || remainder.hasPrefix("?") || remainder.hasPrefix("#") else {
            return nil
        }
        let parts = splitRemainder(remainder)
        if parsed.isIPv6 {
            return ipv6URL(host: parsed.host, port: parsed.port, path: parts.path, query: parts.query, fragment: parts.fragment)
        }
        var components = URLComponents()
        components.scheme = parsed.usesHTTP ? "http" : "https"
        components.host = parsed.host
        components.port = parsed.port
        if !parts.path.isEmpty {
            components.percentEncodedPath = percentEncode(parts.path, allowed: .urlPathAllowed)
        }
        if let query = parts.query {
            components.percentEncodedQuery = percentEncode(query, allowed: .urlQueryAllowed)
        }
        if let fragment = parts.fragment {
            components.percentEncodedFragment = percentEncode(fragment, allowed: .urlFragmentAllowed)
        }
        return components.url
    }

    /// Splits `host[:port][/path][?query][#fragment]`, keeping bracketed IPv6 hosts intact.
    private static func splitAuthority(_ text: String) -> (String, String) {
        if text.hasPrefix("[") {
            guard let bracket = text.firstIndex(of: "]") else { return (text, "") }
            var index = text.index(after: bracket)
            if index < text.endIndex, text[index] == ":" {
                var portEnd = text.index(after: index)
                while portEnd < text.endIndex, text[portEnd].isNumber {
                    portEnd = text.index(after: portEnd)
                }
                let hasDigits = text.index(after: index) < portEnd
                let boundaryOK = portEnd == text.endIndex || "/?#".contains(text[portEnd])
                if hasDigits, boundaryOK {
                    index = portEnd
                } else {
                    return (text, "")
                }
            }
            return (String(text[..<index]), String(text[index...]))
        }
        if let range = text.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) {
            return (String(text[..<range.lowerBound]), String(text[range.lowerBound...]))
        }
        return (text, "")
    }

    private static func splitRemainder(_ remainder: String) -> (path: String, query: String?, fragment: String?) {
        guard !remainder.isEmpty else { return ("", nil, nil) }
        var body = remainder
        var fragment: String?
        if let hash = body.firstIndex(of: "#") {
            fragment = String(body[body.index(after: hash)...])
            body = String(body[..<hash])
        }
        var query: String?
        if let question = body.firstIndex(of: "?") {
            query = String(body[body.index(after: question)...])
            body = String(body[..<question])
        }
        return (body, query, fragment)
    }

    private static func parseAuthority(_ authority: String) -> Authority? {
        if authority.hasPrefix("[") {
            guard let bracket = authority.firstIndex(of: "]") else { return nil }
            let inner = String(authority[authority.index(after: authority.startIndex)..<bracket])
            guard isIPv6(inner) else { return nil }
            let suffix = String(authority[authority.index(after: bracket)...])
            if suffix.isEmpty {
                return Authority(usesHTTP: true, host: inner, port: nil, isIPv6: true)
            }
            guard let port = parsePort(suffix) else { return nil }
            return Authority(usesHTTP: true, host: inner, port: port, isIPv6: true)
        }

        guard let (rawHost, port) = splitHostAndPort(authority) else { return nil }
        let host = stripTrailingDots(rawHost)
        guard !host.isEmpty else { return nil }
        if host.lowercased() == "localhost" {
            return Authority(usesHTTP: true, host: "localhost", port: port, isIPv6: false)
        }
        if isIPv4(host) {
            return Authority(usesHTTP: true, host: host, port: port, isIPv6: false)
        }
        if isDomain(host) {
            return Authority(usesHTTP: false, host: host.lowercased(), port: port, isIPv6: false)
        }
        return nil
    }

    /// `nil` port when there is no colon. `nil` result when a colon is present but the port is invalid.
    private static func splitHostAndPort(_ authority: String) -> (String, Int?)? {
        guard let colon = authority.lastIndex(of: ":") else { return (authority, nil) }
        let host = String(authority[..<colon])
        let suffix = String(authority[colon...])
        guard let port = parsePort(suffix) else { return nil }
        return (host, port)
    }

    private static func parsePort(_ suffix: String) -> Int? {
        guard suffix.hasPrefix(":") else { return nil }
        let digits = suffix.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    private static func stripTrailingDots(_ host: String) -> String {
        var result = host
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part) else { return false }
            return value <= 255
        }
    }

    /// Compressed and full hex forms, including a trailing IPv4 tail (`::ffff:192.0.2.1`).
    private static func isIPv6(_ text: String) -> Bool {
        guard text.contains(":") else { return false }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        let compressed = halves.count == 2

        func hexGroups(_ part: String) -> [String]? {
            if part.isEmpty { return [] }
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard !pieces.contains("") else { return nil }
            return pieces
        }
        guard var left = hexGroups(halves[0]) else { return false }
        guard var right = compressed ? hexGroups(halves[1]) : [] else { return false }
        var extra = 0
        if let last = (right.last ?? left.last), last.contains(".") {
            guard isIPv4(last) else { return false }
            if right.isEmpty { left.removeLast() } else { right.removeLast() }
            extra = 2
        }
        let groups = left + right
        guard groups.allSatisfy({ (1...4).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { return false }
        let count = groups.count + extra
        return compressed ? count < 8 : count == 8
    }

    /// Last label is two or more letters, a punycode label, or `knownSuffixes`.
    private static let knownSuffixes: Set<String> = [
        "local", "internal", "localhost", "test", "example", "invalid", "onion", "arpa", "home", "lan"
    ]

    private static func isDomain(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isValidLabel) else { return false }
        return isNavigableTLD(String(labels[labels.count - 1]))
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func isNavigableTLD(_ tld: String) -> Bool {
        if tld.count >= 2, tld.allSatisfy(\.isLetter) { return true }
        let folded = tld.lowercased()
        if folded.hasPrefix("xn--") { return true }
        return knownSuffixes.contains(folded)
    }

    private static func ipv6URL(host: String, port: Int?, path: String, query: String?, fragment: String?) -> URL? {
        var string = "http://[\(host)]"
        if let port { string += ":\(port)" }
        string += percentEncode(path, allowed: .urlPathAllowed)
        if let query { string += "?\(percentEncode(query, allowed: .urlQueryAllowed))" }
        if let fragment { string += "#\(percentEncode(fragment, allowed: .urlFragmentAllowed))" }
        return URL(string: string)
    }

    private static func percentEncode(_ text: String, allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
