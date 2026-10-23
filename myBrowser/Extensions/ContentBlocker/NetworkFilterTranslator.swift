import Foundation

/// What this WebKit build accepted when a one-rule list was compiled.
nonisolated struct WebKitRuleCapabilities: Codable, Equatable, Sendable {
    var loadContext: Bool
    var ifTopURL: Bool
    var websocket: Bool
    var starredDomain: Bool
    var ifAndUnlessDomain: Bool

    var token: String {
        "lc\(loadContext ? 1 : 0)-top\(ifTopURL ? 1 : 0)-ws\(websocket ? 1 : 0)-star\(starredDomain ? 1 : 0)-and\(ifAndUnlessDomain ? 1 : 0)"
    }

    /// Used before the probe finishes, and by tests that want the full trigger set.
    static let assumed = WebKitRuleCapabilities(
        loadContext: true,
        ifTopURL: true,
        websocket: false,
        starredDomain: true,
        ifAndUnlessDomain: true
    )
}

/// One content-blocker rule, before it is JSON.
nonisolated struct ContentRule: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        case block
        case blockCookies = "block-cookies"
        case ignorePrevious = "ignore-previous-rules"
        case cssDisplayNone = "css-display-none"
    }

    enum Tier: Int, Equatable, Sendable {
        case normal
        case cosmetic
        case exception
        case important
        case importantException
        case whitelist
    }

    var urlFilter: String
    var caseSensitive: Bool = false
    var ifDomain: [String]?
    var unlessDomain: [String]?
    var resourceType: [String]?
    var loadType: [String]?
    var loadContext: [String]?
    var ifTopURL: [String]? = nil
    var selector: String? = nil
    var action: Action
    var tier: Tier
    var isHostAnchored: Bool

    func jsonObject() -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": urlFilter]
        if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
        if let ifDomain, !ifDomain.isEmpty { trigger["if-domain"] = ifDomain }
        if let unlessDomain, !unlessDomain.isEmpty { trigger["unless-domain"] = unlessDomain }
        if let resourceType, !resourceType.isEmpty { trigger["resource-type"] = resourceType }
        if let loadType, !loadType.isEmpty { trigger["load-type"] = loadType }
        if let loadContext, !loadContext.isEmpty { trigger["load-context"] = loadContext }
        if let ifTopURL, !ifTopURL.isEmpty { trigger["if-top-url"] = ifTopURL }
        var actionObject: [String: Any] = ["type": action.rawValue]
        if let selector { actionObject["selector"] = selector }
        return ["trigger": trigger, "action": actionObject]
    }
}

nonisolated struct ContentBlockerStats: Codable, Equatable, Sendable {
    var filterLines: Int = 0
    var converted: Int = 0
    var kept: Int = 0
    var emitted: Int = 0
    var chunks: Int = 0
    var dropped: [String: Int] = [:]
    var compileSeconds: Double = 0

    mutating func drop(_ reason: String, _ count: Int = 1) {
        guard count > 0 else { return }
        dropped[reason, default: 0] += count
    }

    var droppedTotal: Int { dropped.values.reduce(0, +) }

    var summary: String {
        let reasons = dropped.keys.sorted().map { "\($0)=\(dropped[$0] ?? 0)" }.joined(separator: " ")
        return "lines=\(filterLines) converted=\(converted) kept=\(kept) emitted=\(emitted) chunks=\(chunks) dropped=\(droppedTotal) \(reasons)"
    }
}

nonisolated struct ContentRuleCompilation: Sendable {
    var chunks: [[ContentRule]]
    var stats: ContentBlockerStats

    func jsonStrings() -> [String] {
        chunks.compactMap { ContentRuleJSON.encode($0) }
    }
}

nonisolated enum ContentRuleJSON {
    static func encode(_ rules: [ContentRule]) -> String? {
        guard !rules.isEmpty else { return nil }
        let objects = rules.map { $0.jsonObject() }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Compiles static filter text into content-blocker rules.
///
/// Network rules are the priority. Simple cosmetics are included only when they fit.
/// Scriptlets, redirects, CSP, removeparam, and procedural cosmetics are left for uBO.
nonisolated enum FilterCompiler {
    static let maxRulesPerList = 150_000
    static let maxLists = 8
    private static let domainGroup = 50

    static func compile(
        lists: [String],
        userFilters: String,
        whitelist: [String],
        capabilities: WebKitRuleCapabilities,
        maxRules: Int = maxRulesPerList,
        maxLists: Int = maxLists
    ) -> ContentRuleCompilation {
        var stats = ContentBlockerStats()
        var rules: [ContentRule] = []
        for text in lists {
            translate(text, capabilities: capabilities, into: &rules, stats: &stats)
        }
        if !userFilters.isEmpty {
            translate(userFilters, capabilities: capabilities, into: &rules, stats: &stats)
        }
        rules.append(contentsOf: whitelistRules(whitelist, capabilities: capabilities))
        let assembled = assemble(rules, maxRules: max(1, maxRules), maxLists: max(1, maxLists))
        stats.drop("budget", assembled.budgetDropped)
        stats.converted = rules.count
        stats.kept = rules.count - assembled.budgetDropped
        stats.chunks = assembled.chunks.count
        stats.emitted = assembled.chunks.reduce(0) { $0 + $1.count }
        return ContentRuleCompilation(chunks: assembled.chunks, stats: stats)
    }

    static func translateLine(_ line: String, capabilities: WebKitRuleCapabilities) -> [ContentRule] {
        var rules: [ContentRule] = []
        var stats = ContentBlockerStats()
        translate(line, capabilities: capabilities, into: &rules, stats: &stats)
        return rules
    }

    // MARK: Lists

    private static func translate(
        _ text: String,
        capabilities: WebKitRuleCapabilities,
        into rules: inout [ContentRule],
        stats: inout ContentBlockerStats
    ) {
        var stack: [IfFrame] = []
        var skipping = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("!#if") {
                let expr = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                let result = Preprocessor.eval(String(expr))
                stack.append(IfFrame(discard: result == false))
                skipping = stack.contains(where: \.discard)
                continue
            }
            if line.hasPrefix("!#else") {
                if !stack.isEmpty {
                    stack[stack.count - 1].discard.toggle()
                }
                skipping = stack.contains(where: \.discard)
                continue
            }
            if line.hasPrefix("!#endif") {
                if !stack.isEmpty { stack.removeLast() }
                skipping = stack.contains(where: \.discard)
                continue
            }
            if line.hasPrefix("!#") || skipping { continue }
            switch classify(line, capabilities: capabilities) {
            case .skip:
                break
            case .drop(let reason):
                stats.filterLines += 1
                stats.drop(reason)
            case .rules(let translated):
                stats.filterLines += 1
                rules.append(contentsOf: translated)
            }
        }
    }

    private struct IfFrame {
        var discard: Bool
    }

    private enum Classified {
        case skip
        case drop(String)
        case rules([ContentRule])
    }

    private static func classify(
        _ line: String,
        capabilities: WebKitRuleCapabilities
    ) -> Classified {
        if line.hasPrefix("!") || line.hasPrefix("[") { return .skip }
        if line.hasPrefix("#"), !line.hasPrefix("##"), !line.hasPrefix("#@#"), !line.hasPrefix("#?#"), !line.hasPrefix("#$#"), !line.hasPrefix("#%#") {
            return .skip
        }
        if let cosmetic = cosmeticSeparator(in: line) {
            return translateCosmetic(line, separator: cosmetic, capabilities: capabilities)
        }
        if let hostLine = hostsLine(line) {
            if isHostWideGooglevideo("||\(hostLine)^") { return .drop("googlevideo") }
            return translateNetwork("||\(hostLine)^", capabilities: capabilities)
        }
        return translateNetwork(line, capabilities: capabilities)
    }

    // MARK: Cosmetic

    /// Longest anchor first. `#@?#` is not a prefix of `#@#`.
    private static let cosmeticSeparators = ["#@?#", "#@$#", "#@%#", "#@#", "#?#", "#$#", "#%#", "##"]

    private static func cosmeticSeparator(in line: String) -> (separator: String, index: String.Index)? {
        var best: (String, String.Index)?
        for separator in cosmeticSeparators {
            guard let index = line.range(of: separator)?.lowerBound else { continue }
            if best == nil || index < best!.1 {
                best = (separator, index)
            }
        }
        guard let best else { return nil }
        let left = line[..<best.1]
        // `||host/path##` is a URL, not a cosmetic domain list.
        if left.contains("||") || left.contains("://") || left.hasPrefix("|") || left.hasPrefix("/") {
            return nil
        }
        return (best.0, best.1)
    }

    private static func translateCosmetic(
        _ line: String,
        separator: (separator: String, index: String.Index),
        capabilities: WebKitRuleCapabilities
    ) -> Classified {
        let left = line[..<separator.index]
        let selectorStart = line.index(separator.index, offsetBy: separator.separator.count)
        let selector = String(line[selectorStart...]).trimmingCharacters(in: .whitespaces)
        if separator.separator != "##" { return .drop(separator.separator == "#@#" ? "cosmetic-exception" : "procedural") }
        if selector.hasPrefix("+js") || selector.contains(":style(") { return .drop("scriptlet") }
        if !isSimpleSelector(selector) { return .drop("cosmetic-unsupported") }
        let domains = parseDomains(String(left).replacingOccurrences(of: ",", with: "|"))
        switch domains {
        case .entity:
            return .drop("entity-domain")
        case .list(let positive, let negative):
            if !negative.isEmpty && !positive.isEmpty && !capabilities.ifAndUnlessDomain {
                return .drop("entity-domain")
            }
            guard let groups = domainGroups(positive, negative) else { return .drop("budget") }
            let rules = groups.map { group in
                ContentRule(
                    urlFilter: ".*",
                    ifDomain: webKitDomains(group.positive, capabilities),
                    unlessDomain: webKitDomains(group.negative, capabilities),
                    selector: selector,
                    action: .cssDisplayNone,
                    tier: .cosmetic,
                    isHostAnchored: false
                )
            }
            return .rules(rules)
        }
    }

    private static func isSimpleSelector(_ selector: String) -> Bool {
        if selector.isEmpty || selector.count > 400 { return false }
        if selector.contains(":") || selector.contains("/") || selector.contains("(") || selector.contains(")") { return false }
        let allowed = CharacterSet(charactersIn: "#.[]=_'\"~|^$* >+~-,")
        return selector.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || allowed.contains($0) }
    }

    // MARK: Network

    private static func translateNetwork(_ line: String, capabilities: WebKitRuleCapabilities) -> Classified {
        var body = line
        var exception = false
        if body.hasPrefix("@@") {
            exception = true
            body.removeFirst(2)
        }
        let pattern: String
        let optionText: String
        if let regex = regexFilter(body) {
            if !isSafeSourceRegex(regex.body) { return .drop("regex") }
            pattern = ""
            optionText = regex.options
            return finish(
                pattern: pattern,
                regex: regex.body,
                options: optionText,
                exception: exception,
                capabilities: capabilities,
                sourceIsRegex: true
            )
        }
        if let dollar = body.firstIndex(of: "$") {
            pattern = String(body[..<dollar])
            optionText = String(body[body.index(after: dollar)...])
        } else {
            pattern = body
            optionText = ""
        }
        return finish(
            pattern: pattern,
            regex: nil,
            options: optionText,
            exception: exception,
            capabilities: capabilities,
            sourceIsRegex: false
        )
    }

    private static func finish(
        pattern: String,
        regex explicit: String?,
        options optionText: String,
        exception: Bool,
        capabilities: WebKitRuleCapabilities,
        sourceIsRegex: Bool
    ) -> Classified {
        if isHostWideGooglevideo(pattern) { return .drop("googlevideo") }
        let parsed = parseOptions(optionText)
        if let reason = parsed.drop { return .drop(reason) }
        if parsed.cosmeticOnly { return .drop(exception ? "cosmetic-exception" : "cosmetic-unsupported") }
        if !parsed.toNegative.isEmpty { return .drop("to-negated") }

        let patterns = expandedPatterns(
            pattern: pattern,
            explicitRegex: explicit,
            sourceIsRegex: sourceIsRegex,
            toPositive: parsed.toPositive
        )
        switch patterns {
        case .drop(let reason):
            return .drop(reason)
        case .patterns(let items):
            if !parsed.domainsNegative.isEmpty && !parsed.domainsPositive.isEmpty && !capabilities.ifAndUnlessDomain {
                return .drop("entity-domain")
            }
            guard let groups = domainGroups(parsed.domainsPositive, parsed.domainsNegative) else { return .drop("budget") }
            let resources = resourceTriggers(parsed, capabilities: capabilities)
            if let reason = resources.drop { return .drop(reason) }
            var rules: [ContentRule] = []
            for item in items {
                let unrestricted = item.regex == ".*"
                    && groups.allSatisfy { $0.positive.isEmpty && $0.negative.isEmpty }
                    && resources.types == nil
                    && resources.loadType == nil
                    && resources.loadContext == nil
                if unrestricted { return .drop("too-broad") }
                let action: ContentRule.Action
                let tier: ContentRule.Tier
                if exception && parsed.important {
                    action = .ignorePrevious
                    tier = .importantException
                } else if exception {
                    action = .ignorePrevious
                    tier = .exception
                } else if parsed.cookieBlock {
                    action = .blockCookies
                    tier = parsed.important ? .important : .normal
                } else if parsed.important {
                    action = .block
                    tier = .important
                } else {
                    action = .block
                    tier = .normal
                }
                for group in groups {
                    rules.append(ContentRule(
                        urlFilter: item.regex,
                        caseSensitive: parsed.matchCase,
                        ifDomain: webKitDomains(group.positive, capabilities),
                        unlessDomain: webKitDomains(group.negative, capabilities),
                        resourceType: resources.types,
                        loadType: resources.loadType,
                        loadContext: resources.loadContext,
                        action: action,
                        tier: tier,
                        isHostAnchored: item.hostAnchored
                    ))
                }
            }
            return rules.isEmpty ? .drop("unsupported-option") : .rules(rules)
        }
    }

    private struct PatternItem {
        var regex: String
        var hostAnchored: Bool
    }

    private enum Expanded {
        case patterns([PatternItem])
        case drop(String)
    }

    private static func expandedPatterns(
        pattern: String,
        explicitRegex: String?,
        sourceIsRegex: Bool,
        toPositive: [String]
    ) -> Expanded {
        if sourceIsRegex, let explicitRegex {
            guard explicitRegex.count <= 2_000, (try? NSRegularExpression(pattern: explicitRegex)) != nil else {
                return .drop("regex")
            }
            if !toPositive.isEmpty { return .drop("to-complex") }
            return .patterns([PatternItem(regex: explicitRegex, hostAnchored: false)])
        }
        if !toPositive.isEmpty {
            if isMatchAll(pattern) {
                return .patterns(toPositive.map {
                    PatternItem(regex: anchoredHostRegex($0), hostAnchored: true)
                })
            }
            if let host = bareAnchoredHost(pattern), toPositive.count == 1,
               host.caseInsensitiveCompare(toPositive[0]) == .orderedSame {
                // `to=` repeats the host the pattern already names.
            } else {
                return .drop("to-complex")
            }
        }
        guard let regex = patternRegex(pattern) else { return .drop("regex") }
        guard regex.count <= 2_000, regex.unicodeScalars.allSatisfy(\.isASCII) else { return .drop("regex") }
        return .patterns([PatternItem(regex: regex, hostAnchored: pattern.hasPrefix("||") && !pattern.contains("*"))])
    }

    private static func isMatchAll(_ pattern: String) -> Bool {
        pattern.isEmpty || pattern == "*" || pattern == "^" || pattern == "||" || pattern == "|"
    }

    private static func anchoredHostRegex(_ host: String) -> String {
        "^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?" + escapeRegex(host) + "[^0-9A-Za-z_%.-]"
    }

    private static func bareAnchoredHost(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        let rest = pattern.dropFirst(2)
        let host = rest.prefix { character in
            character != "^" && character != "/" && character != "*" && character != "|" && character != "?" && character != "$"
        }
        let suffix = rest.dropFirst(host.count)
        guard suffix.isEmpty || suffix == "^" else { return nil }
        return host.isEmpty ? nil : String(host)
    }

    static func isHostWideGooglevideo(_ pattern: String) -> Bool {
        guard let host = bareAnchoredHost(pattern)?.lowercased() else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    /// `||host^` matches that host and its subdomains, not a longer label and not a suffix of another host.
    static func patternRegex(_ pattern: String) -> String? {
        if isMatchAll(pattern) { return ".*" }
        var body = pattern
        var hostAnchor = false
        var startAnchor = false
        var endAnchor = false
        if body.hasPrefix("||") {
            hostAnchor = true
            body.removeFirst(2)
        } else if body.hasPrefix("|") {
            startAnchor = true
            body.removeFirst()
        }
        if body.hasSuffix("|") {
            endAnchor = true
            body.removeLast()
        }
        if hostAnchor && body.isEmpty { return ".*" }
        var out = ""
        out.reserveCapacity(body.count + 32)
        if hostAnchor {
            out += "^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?"
        } else if startAnchor {
            out += "^"
        }
        var stars = 0
        var iterator = body.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\\":
                guard let escaped = iterator.next() else { return nil }
                out += escapeRegex(String(escaped))
            case "*":
                out += ".*"
                stars += 1
                if stars > 6 { return nil }
            case "^":
                // WebKit's content-blocker parser rejects `|`, so this cannot also match
                // the end of the URL. A request that ends exactly on the token is missed.
                out += "[^0-9A-Za-z_%.-]"
            default:
                out += escapeRegex(String(character))
            }
        }
        if endAnchor { out += "$" }
        return out
    }

    private static func escapeRegex(_ literal: String) -> String {
        var out = ""
        for character in literal {
            if "\\.^$+?()[]{}|".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func regexFilter(_ body: String) -> (body: String, options: String)? {
        guard body.hasPrefix("/") else { return nil }
        let chars = Array(body)
        var index = 1
        while index < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == "/" {
                let next = index + 1
                if next == chars.count {
                    return (String(chars[1..<index]), "")
                }
                if chars[next] == "$" {
                    return (String(chars[1..<index]), String(chars[(next + 1)...]))
                }
                return nil
            }
            index += 1
        }
        return nil
    }

    private static func isSafeSourceRegex(_ body: String) -> Bool {
        if body.count > 2_000 || body.contains("(?") || body.contains("\\b") { return false }
        // URLFilterParser rejects disjunctions, `{n,m}`, word classes, and non-ASCII.
        if body.contains("|") || body.contains("{") { return false }
        if body.contains("\\d") || body.contains("\\D") || body.contains("\\w") || body.contains("\\W")
            || body.contains("\\s") || body.contains("\\S") { return false }
        if !body.unicodeScalars.allSatisfy(\.isASCII) { return false }
        for digit in "123456789" where body.contains("\\\(digit)") { return false }
        return true
    }

    // MARK: Options

    private struct ParsedOptions {
        var important = false
        var matchCase = false
        var cookieBlock = false
        var cosmeticOnly = false
        var drop: String?
        var firstParty = false
        var thirdParty = false
        var domainsPositive: [String] = []
        var domainsNegative: [String] = []
        var toPositive: [String] = []
        var toNegative: [String] = []
        var positiveTypes: Set<ResourceKind> = []
        var negativeTypes: Set<ResourceKind> = []
        var sawUnmapped = false
        var sawType = false
        var sawCosmeticModifier = false
    }

    private enum ResourceKind: Hashable {
        case script, image, style, font, media, ping, popup, document, subdocument, xhr, websocket
    }

    private static func parseOptions(_ text: String) -> ParsedOptions {
        var parsed = ParsedOptions()
        if text.isEmpty { return parsed }
        let parts = splitOptions(text)
        var sawNetworkRestriction = false
        for part in parts {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            let name: String
            let value: String?
            if let eq = token.firstIndex(of: "=") {
                name = String(token[..<eq]).lowercased()
                value = String(token[token.index(after: eq)...])
            } else {
                name = token.lowercased()
                value = nil
            }
            if name == "reason" { continue }
            if let reason = droppingOption(name) {
                parsed.drop = reason
                return parsed
            }
            var negated = false
            var typeName = name
            if typeName.hasPrefix("~") {
                negated = true
                typeName.removeFirst()
            }
            switch typeName {
            case "important":
                parsed.important = true
            case "match-case":
                parsed.matchCase = true
            case "third-party", "3p":
                sawNetworkRestriction = true
                if negated { parsed.firstParty = true } else { parsed.thirdParty = true }
            case "first-party", "1p":
                sawNetworkRestriction = true
                if negated { parsed.thirdParty = true } else { parsed.firstParty = true }
            case "domain", "from":
                switch parseDomains(value ?? "") {
                case .entity:
                    parsed.drop = "entity-domain"
                    return parsed
                case .list(let positive, let negative):
                    parsed.domainsPositive.append(contentsOf: positive)
                    parsed.domainsNegative.append(contentsOf: negative)
                }
            case "to":
                switch parseDomains(value ?? "") {
                case .entity:
                    parsed.drop = "entity-domain"
                    return parsed
                case .list(let positive, let negative):
                    parsed.toPositive.append(contentsOf: positive)
                    parsed.toNegative.append(contentsOf: negative)
                }
            case "cookie":
                if negated || (value?.isEmpty == false) {
                    parsed.drop = "named-cookie"
                    return parsed
                }
                parsed.cookieBlock = true
                sawNetworkRestriction = true
            case "all":
                parsed.sawType = true
                sawNetworkRestriction = true
            case "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide":
                parsed.sawCosmeticModifier = true
            default:
                if let kind = resourceKind(typeName) {
                    parsed.sawType = true
                    sawNetworkRestriction = true
                    if negated {
                        parsed.negativeTypes.insert(kind)
                    } else {
                        parsed.positiveTypes.insert(kind)
                    }
                } else if isKnownUnmapped(typeName) {
                    parsed.sawType = true
                    parsed.sawUnmapped = true
                    sawNetworkRestriction = true
                } else {
                    parsed.drop = "unsupported-option"
                    return parsed
                }
            }
        }
        if parsed.firstParty && parsed.thirdParty {
            parsed.firstParty = false
            parsed.thirdParty = false
        }
        parsed.cosmeticOnly = parsed.sawCosmeticModifier && !sawNetworkRestriction
        return parsed
    }

    private static func droppingOption(_ name: String) -> String? {
        switch name {
        case "redirect", "redirect-rule", "rewrite", "empty", "mp4":
            return "redirect"
        case "csp":
            return "csp"
        case "removeparam":
            return "removeparam"
        case "replace":
            return "replace"
        case "urlskip":
            return "urlskip"
        case "badfilter":
            return "badfilter"
        case "permissions", "header", "method", "cname", "ipaddress", "denyallow", "strict1p", "strict3p":
            return "unsupported-option"
        default:
            return nil
        }
    }

    private static func resourceKind(_ name: String) -> ResourceKind? {
        switch name {
        case "script": return .script
        case "image": return .image
        case "stylesheet", "css": return .style
        case "font": return .font
        case "media": return .media
        case "ping", "beacon": return .ping
        case "popup", "popunder": return .popup
        case "document", "doc": return .document
        case "frame", "subdocument": return .subdocument
        case "xhr", "xmlhttprequest": return .xhr
        case "websocket": return .websocket
        default: return nil
        }
    }

    private static func isKnownUnmapped(_ name: String) -> Bool {
        switch name {
        case "object", "object-subrequest", "other", "webrtc", "inline-script":
            return true
        default:
            return false
        }
    }

    private struct ResourceTriggers {
        var types: [String]?
        var loadType: [String]?
        var loadContext: [String]?
        var drop: String?
    }

    private static func resourceTriggers(_ parsed: ParsedOptions, capabilities: WebKitRuleCapabilities) -> ResourceTriggers {
        var result = ResourceTriggers()
        if parsed.firstParty && !parsed.thirdParty { result.loadType = ["first-party"] }
        if parsed.thirdParty && !parsed.firstParty { result.loadType = ["third-party"] }
        if parsed.positiveTypes.isEmpty && parsed.negativeTypes.isEmpty && !parsed.sawUnmapped {
            return result
        }
        let mappedPositive = parsed.positiveTypes
        if mappedPositive.isEmpty && parsed.sawUnmapped && parsed.negativeTypes.isEmpty {
            result.drop = "unsupported-option"
            return result
        }
        if mappedPositive.isEmpty && !parsed.negativeTypes.isEmpty {
            var all = Set(allWebKitTypes())
            for kind in parsed.negativeTypes {
                if let name = webKitName(kind, capabilities: capabilities) {
                    all.remove(name)
                }
            }
            if all.isEmpty {
                result.drop = "unsupported-option"
                return result
            }
            result.types = all.sorted()
            return result
        }
        var names: [String] = []
        var frames: Set<ResourceKind> = []
        var others = false
        for kind in mappedPositive {
            if kind == .document || kind == .subdocument {
                frames.insert(kind)
            } else {
                others = true
            }
            if kind == .websocket && !capabilities.websocket { continue }
            if let name = webKitName(kind, capabilities: capabilities) {
                names.append(name)
            }
        }
        if names.isEmpty {
            result.drop = mappedPositive.contains(.websocket) ? "websocket" : "unsupported-option"
            return result
        }
        if frames == [.subdocument], !others, !capabilities.loadContext {
            result.drop = "subdocument"
            return result
        }
        if !others, capabilities.loadContext {
            if frames == [.document] { result.loadContext = ["top-frame"] }
            if frames == [.subdocument] { result.loadContext = ["child-frame"] }
        }
        result.types = Array(Set(names)).sorted()
        return result
    }

    private static func webKitName(_ kind: ResourceKind, capabilities: WebKitRuleCapabilities) -> String? {
        switch kind {
        case .script: return "script"
        case .image: return "image"
        case .style: return "style-sheet"
        case .font: return "font"
        case .media: return "media"
        case .ping: return "ping"
        case .popup: return "popup"
        case .document, .subdocument: return "document"
        case .xhr: return "raw"
        case .websocket: return capabilities.websocket ? "websocket" : nil
        }
    }

    private static func allWebKitTypes() -> [String] {
        ["document", "font", "image", "media", "ping", "popup", "raw", "script", "style-sheet"]
    }

    private static func splitOptions(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let active = quote {
                current.append(character)
                if character == active { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                continue
            }
            if character == "," {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: Domains

    private enum DomainList {
        case list([String], [String])
        case entity
    }

    private static func parseDomains(_ value: String) -> DomainList {
        if value.isEmpty { return .list([], []) }
        var positive: [String] = []
        var negative: [String] = []
        for raw in value.split(separator: "|") {
            var token = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if token.isEmpty { continue }
            var negated = false
            if token.hasPrefix("~") {
                negated = true
                token.removeFirst()
            }
            if token.hasPrefix("*.") { token.removeFirst(2) }
            if token.contains("*") || token.contains("/") || token.contains(":") { return .entity }
            if token.isEmpty { continue }
            if negated { negative.append(token) } else { positive.append(token) }
        }
        return .list(positive, negative)
    }

    private struct DomainGroup {
        var positive: [String]
        var negative: [String]
    }

    private static func domainGroups(_ positive: [String], _ negative: [String]) -> [DomainGroup]? {
        if positive.isEmpty && negative.isEmpty { return [DomainGroup(positive: [], negative: [])] }
        if negative.count > domainGroup * 2 || positive.count > 2_000 { return nil }
        let positiveChunks = chunks(positive)
        let negativeChunks = chunks(negative)
        if positiveChunks.count * negativeChunks.count > 32 { return nil }
        var groups: [DomainGroup] = []
        for left in positiveChunks {
            for right in negativeChunks {
                groups.append(DomainGroup(positive: left, negative: right))
            }
        }
        return groups
    }

    private static func chunks(_ values: [String]) -> [[String]] {
        if values.isEmpty { return [[]] }
        var out: [[String]] = []
        var index = 0
        while index < values.count {
            let end = min(index + domainGroup, values.count)
            out.append(Array(values[index..<end]))
            index = end
        }
        return out
    }

    private static func webKitDomains(_ hosts: [String], _ capabilities: WebKitRuleCapabilities) -> [String]? {
        if hosts.isEmpty { return nil }
        if capabilities.starredDomain {
            return hosts.map { "*\($0)" }
        }
        return hosts
    }

    // MARK: Hosts

    private static func hostsLine(_ line: String) -> String? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2 else { return nil }
        let ip = parts[0]
        guard ip == "0.0.0.0" || ip == "127.0.0.1" || ip == "::" || ip == "::1" else { return nil }
        let host = parts[1]
        if host.hasPrefix("#") || host == "localhost" || host == "local" || host == "localdomain" || host == "broadcasthost" {
            return nil
        }
        if host.contains("/") || host.contains("*") { return nil }
        return host
    }

    // MARK: Whitelist

    static func whitelistRules(_ directives: [String], capabilities: WebKitRuleCapabilities) -> [ContentRule] {
        var rules: [ContentRule] = []
        for raw in directives {
            let directive = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if directive.isEmpty || directive.hasPrefix("#") || directive.contains("-scheme") { continue }
            if directive.hasPrefix("/"), directive.hasSuffix("/"), directive.count >= 2 {
                let body = String(directive.dropFirst().dropLast())
                guard capabilities.ifTopURL, isSafeSourceRegex(body),
                      (try? NSRegularExpression(pattern: body)) != nil else { continue }
                rules.append(whitelist(ifTopURL: [body], ifDomain: nil))
                continue
            }
            if !directive.contains("/") {
                if directive.contains("*") {
                    if capabilities.ifTopURL {
                        let regex = "^" + escapeRegex(directive).replacingOccurrences(of: "\\*", with: ".*")
                        rules.append(whitelist(ifTopURL: [regex], ifDomain: nil))
                    }
                    continue
                }
                let host = directive.lowercased()
                rules.append(whitelist(ifTopURL: nil, ifDomain: webKitDomains([host], capabilities)))
                continue
            }
            if capabilities.ifTopURL {
                rules.append(whitelist(ifTopURL: ["^" + escapeRegex(directive) + "$"], ifDomain: nil))
            } else if let host = URL(string: directive)?.host?.lowercased(), !host.isEmpty {
                rules.append(whitelist(ifTopURL: nil, ifDomain: webKitDomains([host], capabilities)))
            }
        }
        return rules
    }

    private static func whitelist(ifTopURL: [String]?, ifDomain: [String]?) -> ContentRule {
        ContentRule(
            urlFilter: ".*",
            ifDomain: ifDomain,
            ifTopURL: ifTopURL,
            action: .ignorePrevious,
            tier: .whitelist,
            isHostAnchored: true
        )
    }

    // MARK: Assemble

    private static func assemble(
        _ rules: [ContentRule],
        maxRules: Int,
        maxLists: Int
    ) -> (chunks: [[ContentRule]], budgetDropped: Int) {
        var normal: [ContentRule] = []
        var cosmetic: [ContentRule] = []
        var exception: [ContentRule] = []
        var important: [ContentRule] = []
        var importantException: [ContentRule] = []
        var whitelist: [ContentRule] = []
        for rule in rules {
            switch rule.tier {
            case .normal: normal.append(rule)
            case .cosmetic: cosmetic.append(rule)
            case .exception: exception.append(rule)
            case .important: important.append(rule)
            case .importantException: importantException.append(rule)
            case .whitelist: whitelist.append(rule)
            }
        }
        var reserved = exception + important + importantException + whitelist
        var dropped = shrink(&reserved, maxCount: max(1, maxRules - 1))
        let room = max(1, maxRules - reserved.count)
        let capacity = room * maxLists
        if normal.count + cosmetic.count > capacity {
            dropped += cosmetic.count
            cosmetic.removeAll()
        }
        if normal.count > capacity {
            let anchored = normal.filter(\.isHostAnchored)
            let loose = normal.filter { !$0.isHostAnchored }
            if anchored.count >= capacity {
                dropped += anchored.count - capacity
                dropped += loose.count
                normal = Array(anchored.prefix(capacity))
            } else {
                let keepLoose = capacity - anchored.count
                dropped += loose.count - keepLoose
                normal = anchored + Array(loose.prefix(keepLoose))
            }
        }
        let body = normal + cosmetic
        if body.isEmpty {
            if reserved.isEmpty { return ([], dropped) }
            return ([reserved], dropped)
        }
        var chunks: [[ContentRule]] = []
        var index = 0
        while index < body.count && chunks.count < maxLists {
            let end = min(index + room, body.count)
            chunks.append(Array(body[index..<end]) + reserved)
            index = end
        }
        if index < body.count {
            dropped += body.count - index
        }
        return (chunks, dropped)
    }

    private static func shrink(_ reserved: inout [ContentRule], maxCount: Int) -> Int {
        var dropped = 0
        func drop(_ matches: (ContentRule) -> Bool) {
            while reserved.count > maxCount, let index = reserved.firstIndex(where: matches) {
                reserved.remove(at: index)
                dropped += 1
            }
        }
        drop { $0.tier == .exception && !$0.isHostAnchored }
        drop { $0.tier == .exception }
        drop { $0.tier == .important && !$0.isHostAnchored }
        drop { $0.tier == .important }
        drop { $0.tier == .importantException && !$0.isHostAnchored }
        drop { $0.tier == .importantException }
        while reserved.count > maxCount {
            reserved.removeFirst()
            dropped += 1
        }
        return dropped
    }
}

/// Full uBO keeps the non-mobile, non-Lite branch. Unknown tokens stay included so a new
/// list does not silently lose its filters; `!#else` then takes the other branch.
nonisolated enum Preprocessor {
    private static let trueStates: Set<String> = ["ublock", "html_filtering"]
    private static let states: [String: String] = [
        "ext_ublock": "ublock",
        "ext_ubol": "ubol",
        "ext_devbuild": "devbuild",
        "ext_abp": "false",
        "env_brave": "brave",
        "env_chromium": "chromium",
        "env_edge": "edge",
        "env_firefox": "firefox",
        "env_legacy": "legacy",
        "env_mobile": "mobile",
        "env_mv3": "mv3",
        "env_safari": "safari",
        "cap_html_filtering": "html_filtering",
        "cap_ipaddress": "ipaddress",
        "false": "false",
        "adguard": "adguard",
        "adguard_ext_chromium": "chromium",
        "adguard_ext_firefox": "firefox",
        "adguard_ext_safari": "false"
    ]

    static func eval(_ expr: String) -> Bool {
        var text = expr.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), text.hasSuffix(")") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if text.isEmpty { return true }
        let pieces = tokens(text)
        guard let first = pieces.first else { return true }
        var value = evalToken(first.token)
        for piece in pieces.dropFirst() {
            let next = evalToken(piece.token)
            if piece.op == "||" {
                value = value || next
            } else {
                value = value && next
            }
        }
        return value
    }

    private struct Piece {
        var op: String
        var token: String
    }

    private static func tokens(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = ""
        var pendingOp = ""
        func flush() {
            let token = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !token.isEmpty else { return }
            pieces.append(Piece(op: pendingOp, token: token))
            pendingOp = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("&&") {
                flush()
                pendingOp = "&&"
                index = text.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("||") {
                flush()
                pendingOp = "||"
                index = text.index(index, offsetBy: 2)
                continue
            }
            current.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return pieces
    }

    private static func evalToken(_ raw: String) -> Bool {
        var token = raw.trimmingCharacters(in: .whitespaces)
        var negated = false
        if token.hasPrefix("!") {
            negated = true
            token.removeFirst()
        }
        let state: String
        if let mapped = states[token] {
            state = mapped
        } else if token.hasPrefix("cap_") {
            state = "false"
        } else {
            return !negated
        }
        if state == "false" { return negated }
        let included = trueStates.contains(state)
        return included != negated
    }
}
