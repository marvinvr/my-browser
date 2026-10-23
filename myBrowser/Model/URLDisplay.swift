import Foundation

/// How a page URL is shown in the address field when it is not being edited.
///
/// The host is the primary run, without a scheme or a leading `www.`. At most the last two
/// word-like path segments follow, each separated by a padded slash. Short pieces, locales,
/// versions, and ids are omitted. Queries and fragments are omitted. The stored `absolute`
/// string is still the real URL. Public `http` is `.insecure`. Relaxed hosts (localhost,
/// single-label names, LAN and tailnet suffixes, private and CGNAT addresses, any explicit
/// port) stay quiet; `https` shows no security decoration.
nonisolated struct URLDisplay: Equatable, Sendable {
    nonisolated enum Security: Equatable, Sendable {
        /// https, a local http host, file, or anything else that should stay quiet.
        case none
        /// Public `http`. The field shows a warning.
        case insecure
    }

    nonisolated enum Kind: Equatable, Sendable {
        case host
        case separator
        case path
        case ellipsis
    }

    nonisolated struct Piece: Equatable, Sendable {
        var kind: Kind
        var text: String
    }

    var pieces: [Piece]
    var security: Security
    /// The real URL, for editing, copying, and accessibility.
    var absolute: String

    var isEmpty: Bool { pieces.isEmpty }

    /// Single line, separators already padded (`github.com  /  marvinvr`).
    var plainText: String { pieces.map(\.text).joined() }

    static let empty = URLDisplay(pieces: [], security: .none, absolute: "")

    static let maxPathSegments = 2
    static let maxHostLength = 36
    static let maxSegmentLength = 24

    static func format(_ url: URL?) -> URLDisplay {
        guard let url else { return .empty }
        let absolute = url.absoluteString
        if url.isFileURL {
            let name = fileName(of: url)
            let text = name.isEmpty ? "file" : truncateTail(name, limit: maxSegmentLength)
            return URLDisplay(
                pieces: [Piece(kind: .host, text: text)],
                security: .none,
                absolute: absolute
            )
        }

        let security = security(of: url)
        guard let host = hostText(of: url) else {
            let text = truncateMiddle(absolute, limit: maxHostLength)
            let pieces = text.isEmpty ? [] : [Piece(kind: .host, text: text)]
            return URLDisplay(pieces: pieces, security: security, absolute: absolute)
        }

        var pieces = [Piece(kind: .host, text: host)]
        for segment in visiblePathSegments(of: url) {
            pieces.append(Piece(kind: .separator, text: separator))
            pieces.append(Piece(kind: .path, text: truncateTail(segment, limit: maxSegmentLength)))
        }
        return URLDisplay(pieces: pieces, security: security, absolute: absolute)
    }

    // MARK: - Host

    private static let separator = "  /  "

    private static func hostText(of url: URL) -> String? {
        guard let raw = url.host(percentEncoded: false), !raw.isEmpty else { return nil }
        let decoded = stripWWW(decodeIDN(raw))
        guard !decoded.isEmpty else { return nil }
        let ipv6 = decoded.contains(":")
        let body = isIPAddress(decoded) ? decoded : truncateMiddle(decoded, limit: maxHostLength)
        guard let port = displayPort(of: url) else { return body }
        return ipv6 ? "[\(body)]:\(port)" : "\(body):\(port)"
    }

    /// `URL.port` keeps an explicit `:443` / `:80`. Those are the scheme defaults and stay hidden.
    private static func displayPort(of url: URL) -> Int? {
        guard let port = url.port else { return nil }
        switch url.scheme?.lowercased() {
        case "https" where port == 443: return nil
        case "http" where port == 80: return nil
        default: return port
        }
    }

    /// Leading `www.` only. `www2.example.com` stays.
    private static func stripWWW(_ host: String) -> String {
        guard host.lowercased().hasPrefix("www.") else { return host }
        let rest = String(host.dropFirst(4))
        return rest.isEmpty ? host : rest
    }

    private static func decodeIDN(_ host: String) -> String {
        host.split(separator: ".").map { label -> String in
            let text = String(label)
            let lower = text.lowercased()
            guard lower.hasPrefix("xn--") else { return text }
            return Punycode.decode(String(lower.dropFirst(4))) ?? text
        }.joined(separator: ".")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        return parseIPv4(host) != nil
    }

    // MARK: - Path

    private static func pathSegments(of url: URL) -> [String] {
        let path = url.path(percentEncoded: false)
        return path.split(separator: "/").map { segment -> String in
            let text = String(segment)
            return text.removingPercentEncoding ?? text
        }.filter { !$0.isEmpty }
    }

    /// Last segments that still read as words. `-` and `_` become spaces only when the
    /// segment is a phrase (or a phrase with an id chopped off), not when it is the id itself.
    private static func visiblePathSegments(of url: URL) -> [String] {
        let visible = pathSegments(of: url).compactMap(meaningfulSegment)
        return Array(visible.suffix(maxPathSegments))
    }

    private static let pageExtensions: Set<String> = ["html", "htm", "php", "asp", "aspx", "jsp", "shtml", "cgi"]

    private static func meaningfulSegment(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        let text = stripPageExtension(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return nil }
        if isLocale(text) || isVersion(text) || isUUID(text) || isBareIdentifier(text) { return nil }

        let tokens = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init).filter { !$0.isEmpty }
        let kept = tokens.filter { !isNoiseToken($0) }
        guard kept.contains(where: { $0.filter(\.isLetter).count >= 3 }) else { return nil }
        // A short lowercase stub plus an id (`acct_1A…`, `cus_Nf…`) is still an id.
        // A title with an id chopped off (`My-Page-Title-<hex>`) keeps the words.
        if tokens.contains(where: isOpaqueToken) {
            let words = kept.filter { $0.contains(where: \.isLetter) }
            let readable = words.count >= 2
                || words.contains { $0.count >= 5 }
                || words.contains { $0.contains(where: \.isUppercase) }
            if !readable { return nil }
        }

        let phrase = text.contains("-") || text.contains("_") || kept.count != tokens.count
        return phrase ? kept.joined(separator: " ") : text
    }

    private static func stripPageExtension(_ text: String) -> String {
        guard let dot = text.lastIndex(of: ".") else { return text }
        let ext = text[text.index(after: dot)...].lowercased()
        guard pageExtensions.contains(ext) else { return text }
        let stem = String(text[..<dot])
        return stem.isEmpty ? "" : stem
    }

    /// `de-ch`, `en-US`, `zh-Hans`. A bare `en` is already shorter than 3.
    /// Subtags are 2 letters, or one 4-letter script (`Hans`). `my-browser` does not match.
    private static func isLocale(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard (2...3).contains(parts.count) else { return false }
        guard parts[0].count == 2, parts[0].allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
        return parts.dropFirst().allSatisfy(isLocaleSubtag)
    }

    private static func isLocaleSubtag(_ part: String) -> Bool {
        if part.count == 2, part.allSatisfy(\.isLetter) { return true }
        guard part.count == 4, let first = part.first, first.isUppercase else { return false }
        return part.dropFirst().allSatisfy { $0.isLetter && $0.isLowercase }
    }

    /// `v2`, `v2.0`, `1.2.3`. Plain numbers are handled as numeric noise.
    private static func isVersion(_ text: String) -> Bool {
        let hasPrefix = text.first == "v" || text.first == "V"
        let body = hasPrefix ? String(text.dropFirst()) : text
        guard !body.isEmpty, hasPrefix || text.contains(".") else { return false }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isUUID(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == lengths.count else { return false }
        return zip(parts, lengths).allSatisfy { part, length in
            part.count == length && part.allSatisfy(isHexCharacter)
        }
    }

    private static func isBareIdentifier(_ text: String) -> Bool {
        if text.allSatisfy(\.isNumber) { return true }
        if text.contains("-") || text.contains("_") || text.contains(".") { return false }
        if isOpaqueToken(text) { return true }
        let digits = text.filter(\.isNumber).count
        return digits >= 3 && text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Hex that contains a digit, a full hash length of hex letters, or a long mixed
    /// letter-and-digit run (base64-ish ids, ASINs, Stripe id bodies).
    private static func isOpaqueToken(_ text: String) -> Bool {
        if isMixedID(text) { return true }
        return isHexID(text) && text.contains(where: \.isLetter)
    }

    private static func isNoiseToken(_ token: String) -> Bool {
        if token.allSatisfy(\.isNumber) { return true }
        if isVersion(token) || isLocale(token) || isUUID(token) { return true }
        if isHexID(token) || isMixedID(token) { return true }
        return token.filter(\.isNumber).count >= 3
    }

    private static func isHexID(_ text: String) -> Bool {
        guard text.count >= 4, text.allSatisfy(isHexCharacter) else { return false }
        if text.contains(where: \.isNumber) { return true }
        return text.count == 32 || text.count == 40 || text.count == 64
    }

    private static func isMixedID(_ text: String) -> Bool {
        guard text.count >= 8 else { return false }
        guard text.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let digits = text.filter(\.isNumber).count
        let letters = text.filter(\.isLetter).count
        guard digits > 0, letters > 0 else { return false }
        if digits >= 3 { return true }
        let chars = Array(text)
        for index in chars.indices {
            guard chars[index].isNumber else { continue }
            let before = chars[..<index].contains(where: \.isLetter)
            let after = chars[chars.index(after: index)...].contains(where: \.isLetter)
            if before && after { return true }
        }
        return false
    }

    private static func isHexCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }

    private static func fileName(of url: URL) -> String {
        let segments = pathSegments(of: url)
        if let last = segments.last, !last.isEmpty { return last }
        return ""
    }

    // MARK: - Security

    private static func security(of url: URL) -> Security {
        guard url.scheme?.lowercased() == "http" else { return .none }
        return HTTPRelaxation.isRelaxed(url) ? .none : .insecure
    }

    private static func parseIPv4(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        guard numbers.count == 4 else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    // MARK: - Truncation

    private static func truncateMiddle(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let keep = limit - 1
        let head = keep / 2
        let tail = keep - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    private static func truncateTail(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

/// RFC 3492 punycode decoder for one IDNA label, without the `xn--` prefix.
nonisolated private enum Punycode {
    private static let base = 36
    private static let tmin = 1
    private static let tmax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    static func decode(_ input: String) -> String? {
        let scalars = Array(input.unicodeScalars)
        guard scalars.allSatisfy({ $0.value < 128 }) else { return nil }

        var output: [UInt32] = []
        let delimiter = scalars.lastIndex(of: Unicode.Scalar(45))
        if let delimiter {
            for scalar in scalars[..<delimiter] {
                output.append(scalar.value)
            }
        }

        var index = delimiter.map { scalars.index(after: $0) } ?? scalars.startIndex
        var n = initialN
        var i = 0
        var bias = initialBias

        while index < scalars.endIndex {
            let oldi = i
            var w = 1
            var k = base
            while true {
                guard index < scalars.endIndex, let digit = digitValue(scalars[index]) else { return nil }
                index = scalars.index(after: index)
                let product = digit.multipliedReportingOverflow(by: w)
                guard !product.overflow, i <= Int.max - product.partialValue else { return nil }
                i += product.partialValue
                let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                if digit < t { break }
                let factor = base - t
                guard factor > 0, w <= Int.max / factor else { return nil }
                w *= factor
                guard k <= Int.max - base else { return nil }
                k += base
            }

            let points = output.count + 1
            bias = adapt(delta: i - oldi, numPoints: points, firstTime: oldi == 0)
            guard n <= Int.max - i / points else { return nil }
            n += i / points
            i %= points
            guard (0...0x10FFFF).contains(n), !(0xD800...0xDFFF).contains(n) else { return nil }
            output.insert(UInt32(n), at: i)
            i += 1
        }

        let characters = output.compactMap(Unicode.Scalar.init).map { Character($0) }
        guard characters.count == output.count else { return nil }
        return String(characters)
    }

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        guard numPoints > 0 else { return initialBias }
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= base - tmin
            k += base
        }
        return k + ((base - tmin + 1) * delta) / (delta + skew)
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 48...57: Int(scalar.value) - 22
        case 65...90: Int(scalar.value) - 65
        case 97...122: Int(scalar.value) - 97
        default: nil
        }
    }
}
