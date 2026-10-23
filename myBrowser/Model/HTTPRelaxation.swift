import Darwin
import Foundation

/// Hosts that stay on plain HTTP: no scheme upgrade, no "Not secure" warning.
///
/// Single-label names, tailnet and LAN suffixes, localhost, private and CGNAT
/// addresses, and any host written with an explicit port.
nonisolated enum HTTPRelaxation {
    /// `true` when `host` (no brackets) must not be upgraded and must not be marked insecure.
    static func isRelaxed(host: String, port: Int?) -> Bool {
        if port != nil { return true }
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return false }
        let folded = name.lowercased()
        if folded == "localhost" || folded.hasSuffix(".localhost") { return true }
        if !folded.contains("."), isHostLabel(folded) { return true }
        if hasRelaxedSuffix(folded) { return true }
        if let ipv4 = parseIPv4(folded) { return isPrivateOrLoopback(ipv4) }
        if let bytes = ipv6Bytes(folded) { return isRelaxedIPv6(bytes) }
        return false
    }

    static func isRelaxed(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return isRelaxed(host: host, port: url.port)
    }

    /// The HTTP copy of an HTTPS-first URL, or nil when the URL must stay as requested.
    static func httpFallback(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", !isRelaxed(url) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "http"
        return components.url
    }

    /// Connection, timeout, and certificate failures. DNS and "offline" are not retried as HTTP.
    static func isRetryableHTTPSFailure(_ error: NSError) -> Bool {
        if isRetryable(error) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isRetryable(underlying)
        }
        return false
    }

    static func failingURL(_ error: NSError) -> URL? {
        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let text = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String { return URL(string: text) }
        return nil
    }

    /// Host match for an HTTPS-first failure, including a leading `www.`.
    static func sameSite(host: String, as other: String) -> Bool {
        func strip(_ name: String) -> String {
            let folded = name.lowercased()
            return folded.hasPrefix("www.") ? String(folded.dropFirst(4)) : folded
        }
        return strip(host) == strip(other)
    }

    // MARK: - Names

    private static let suffixes = ["ts.net", "local", "internal", "lan", "home.arpa", "localhost"]

    private static func hasRelaxedSuffix(_ host: String) -> Bool {
        suffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    static func isHostLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: - Addresses

    private static func parseIPv4(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else {
                return nil
            }
            return value
        }
        guard numbers.count == 4 else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    /// 10/8, 127/8, 172.16/12, 192.168/16, and Tailscale CGNAT 100.64/10.
    private static func isPrivateOrLoopback(_ ip: (Int, Int, Int, Int)) -> Bool {
        if ip.0 == 10 || ip.0 == 127 { return true }
        if ip.0 == 192 && ip.1 == 168 { return true }
        if ip.0 == 172 && (16...31).contains(ip.1) { return true }
        if ip.0 == 100 && (64...127).contains(ip.1) { return true }
        return false
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0.prefix(16)) }
    }

    /// Loopback, unique-local (fc00::/7), link-local (fe80::/10), or a mapped private IPv4.
    private static func isRelaxedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if (bytes[0] & 0xfe) == 0xfc { return true }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        if mapped { return isPrivateOrLoopback((Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15]))) }
        return false
    }

    private static func isRetryable(_ error: NSError) -> Bool {
        let domain = error.domain
        let known = domain == NSURLErrorDomain || domain == (kCFErrorDomainCFNetwork as String)
        guard known else { return false }
        return retryableCodes.contains(error.code)
    }

    private static let retryableCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]
}
