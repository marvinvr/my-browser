import Foundation
import Testing
import WebKit
@testable import myBrowser

struct ContentRuleCompilerTests {
    private let caps = WebKitRuleCapabilities.assumed

    @Test func decodesUncompressedSamples() throws {
        let hello = try #require(UOSCDecoder.decode("UOSC_1 '+hello"))
        #expect(hello.string == "hello")
        let lists = try #require(UOSCDecoder.decode("UOSC_1 8('.easylist'1easyprivacy"))
        #expect(lists.stringList == ["easylist", "easyprivacy"])
        let hosts = try #require(UOSCDecoder.decode("UOSC_1 8('1example.com'5www.nytimes.com"))
        #expect(hosts.stringList == ["example.com", "www.nytimes.com"])
    }

    @Test func keepsTheSparseBufferTail() throws {
        let value = try #require(UOSCDecoder.decode("UOSC_1 @& + >+ *+.'/hFj0' !+ "))
        #expect(value.bytes == Data([1, 2, 3, 4, 5]))
    }

    @Test func inflatesAnLZ4FilterList() throws {
        let compressed = "UOSC/lz4_1 6('*size,rZ '*data@& (' >(' ,(' /(?' mH.7<rbQn3&2_??>z<pA/pWFB:m'cG?9bCDtGAQFg5w.B[;z~E:B^w7>~'>Ak~GJG5T73B5cj]DC1Hx(P<H]nUeP]nUeP]nUeP]nfFbaeN-rtDJD&"
        let text = String(repeating: "||cached.example^$third-party\n@@||allow.example^$document\n", count: 80)
        let value = try #require(UOSCDecoder.decode(compressed))
        #expect(value.text == text)
    }

    @Test func translatesEasyListNetworkLines() throws {
        let block = try one("||ad.doubleclick.net^")
        #expect(block.action == .block)
        #expect(block.tier == .normal)
        #expect(block.isHostAnchored)
        #expect(matches(block.urlFilter, "https://ad.doubleclick.net/ddm/track"))
        #expect(matches(block.urlFilter, "https://foo.ad.doubleclick.net/x"))
        #expect(!matches(block.urlFilter, "https://notad.doubleclick.net/x"))
        #expect(!matches(block.urlFilter, "https://ad.doubleclick.net.evil.com/x"))

        let path = try one("||googlesyndication.com/pagead/")
        #expect(matches(path.urlFilter, "https://googlesyndication.com/pagead/js/adsbygoogle.js"))
        #expect(!matches(path.urlFilter, "https://googlesyndication.com/other"))

        let pagead = try one("||pagead2.googlesyndication.com^")
        #expect(matches(pagead.urlFilter, "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"))

        let limited = try one("||googlesyndication.com^$domain=blogto.com|youtube.com")
        #expect(limited.ifDomain == ["*blogto.com", "*youtube.com"])

        let party = try one("||tracker.example^$third-party")
        #expect(party.loadType == ["third-party"])

        let script = try one("||ads.example^$script")
        #expect(script.resourceType == ["script"])

        let redirected = try one("*$to=ad.doubleclick.net")
        #expect(!redirected.urlFilter.contains("|"))
        #expect(matches(redirected.urlFilter, "https://ad.doubleclick.net/pagead"))
        #expect(matches(redirected.urlFilter, "https://foo.ad.doubleclick.net/x"))
        #expect(!matches(redirected.urlFilter, "https://notad.doubleclick.net/x"))
    }

    @Test func translatesExceptionsHostsAndWhitelist() throws {
        let allow = try one("@@||allow.example^$document")
        #expect(allow.action == .ignorePrevious)
        #expect(allow.tier == .exception)
        #expect(allow.resourceType == ["document"])
        #expect(allow.loadContext == ["top-frame"])

        let host = try one("0.0.0.0 ads.example.com")
        #expect(matches(host.urlFilter, "https://ads.example.com/banner"))
        #expect(!matches(host.urlFilter, "https://notads.example.com/banner"))

        let cookies = try one("||track.example^$cookie")
        #expect(cookies.action == .blockCookies)

        let rules = FilterCompiler.whitelistRules(["example.com", "chrome-extension-scheme", "# comment"], capabilities: caps)
        #expect(rules.count == 1)
        #expect(rules[0].tier == .whitelist)
        #expect(rules[0].ifDomain == ["*example.com"])
        #expect(rules[0].action == .ignorePrevious)
    }

    @Test func dropsWhatWouldOverblockOrBreakYouTube() {
        #expect(reason("||ad.example^$redirect=noopjs") == "redirect")
        #expect(reason("||ad.example^$removeparam=utm") == "removeparam")
        #expect(reason("||ad.example^$csp=script-src 'none'") == "csp")
        #expect(reason("||ad.example^$cookie=id") == "named-cookie")
        #expect(reason("||googlevideo.com^") == "googlevideo")
        #expect(reason("||r1---sn.googlevideo.com^") == "googlevideo")
        #expect(reason("*") == "too-broad")
        #expect(reason("||ads.example^$domain=google.*") == "entity-domain")
        #expect(reason("##div:has(.ad)") == "cosmetic-unsupported")
        #expect(reason("example.com#@#.ad") == "cosmetic-exception")
        #expect(reason("example.com##+js(set, x, 1)") == "scriptlet")
        #expect(reason("instagram.com#@?#article") == "procedural")

        let path = FilterCompiler.translateLine("||googlevideo.com/initplayback?source=youtube&*c=TVHTML5&*oad=$xhr,domain=youtube.com", capabilities: caps)
        #expect(path.count == 1)
        #expect(path[0].resourceType == ["raw"])
        #expect(path[0].ifDomain == ["*youtube.com"])
        #expect(matches(path[0].urlFilter, "https://googlevideo.com/initplayback?source=youtube&c=TVHTML5&oad=1"))
    }

    @Test func preprocessorKeepsTheDesktopBranch() {
        let text = """
        !#if env_mobile
        ||mobile.example^
        !#else
        ||desktop.example^
        !#endif
        !#if ext_ubol
        ||lite.example^
        !#endif
        !#if cap_html_filtering
        ||html.example^
        !#endif
        """
        let rules = FilterCompiler.translateLine(text, capabilities: caps)
        let filters = rules.map(\.urlFilter)
        #expect(filters.contains { matches($0, "https://desktop.example/a") })
        #expect(filters.contains { matches($0, "https://html.example/a") })
        #expect(!filters.contains { matches($0, "https://mobile.example/a") })
        #expect(!filters.contains { matches($0, "https://lite.example/a") })
    }

    @Test func simpleCosmeticHidesAndDoesNotUseIgnorePrevious() throws {
        let rule = try one("example.com##.ad-banner")
        #expect(rule.action == .cssDisplayNone)
        #expect(rule.selector == ".ad-banner")
        #expect(rule.ifDomain == ["*example.com"])
        #expect(rule.tier == .cosmetic)
    }

    @Test func assemblerCopiesExceptionsIntoEveryChunk() {
        var rules: [ContentRule] = []
        for index in 0..<10 {
            rules.append(ContentRule(
                urlFilter: "ad\(index)\\.example",
                action: .block,
                tier: .normal,
                isHostAnchored: true
            ))
        }
        rules.append(ContentRule(urlFilter: "allow\\.example", action: .ignorePrevious, tier: .exception, isHostAnchored: true))
        rules.append(ContentRule(
            urlFilter: ".*",
            ifDomain: ["*news.example"],
            action: .ignorePrevious,
            tier: .whitelist,
            isHostAnchored: true
        ))
        rules.append(ContentRule(urlFilter: ".*", selector: ".ad", action: .cssDisplayNone, tier: .cosmetic, isHostAnchored: false))
        let direct = assembleFixture(rules, maxRules: 4, maxLists: 8)
        #expect(direct.chunks.count == 6)
        for chunk in direct.chunks {
            #expect(chunk.contains { $0.tier == .exception })
            #expect(chunk.last?.tier == .whitelist)
            #expect(chunk.filter { $0.tier == .normal }.count <= 2)
        }
        let normals = direct.chunks.flatMap { $0.filter { $0.tier == .normal } }
        #expect(normals.count == 10)
    }

    @Test func dropsCosmeticsBeforeNetworkWhenTheBudgetIsTight() {
        var rules: [ContentRule] = (0..<6).map { index in
            ContentRule(urlFilter: "ad\(index)", action: .block, tier: .normal, isHostAnchored: true)
        }
        rules.append(ContentRule(urlFilter: ".*", selector: ".ad", action: .cssDisplayNone, tier: .cosmetic, isHostAnchored: false))
        let assembled = assembleFixture(rules, maxRules: 3, maxLists: 2)
        let emitted = assembled.chunks.flatMap { $0 }
        #expect(!emitted.contains { $0.tier == .cosmetic })
        #expect(emitted.filter { $0.tier == .normal }.count == 6)
    }

    @Test func readsEnabledListsFromPackageAndStorage() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ubo-set-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
        let assets = """
        {
          "easylist": {"content": "filters", "contentURL": ["assets/easylist.txt"]},
          "annoyances": {"content": "filters", "off": true, "contentURL": ["assets/annoyances.txt"]},
          "regional": {"content": "filters", "contentURL": "https://example.invalid/regional.txt"}
        }
        """
        try assets.write(to: root.appending(path: "assets/assets.json"), atomically: true, encoding: .utf8)
        try "||from.package^\n".write(to: root.appending(path: "assets/easylist.txt"), atomically: true, encoding: .utf8)
        try "||annoyance^\n".write(to: root.appending(path: "assets/annoyances.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache = "\"UOSC_1 '4||from.cache^\\n\""
        let selected = "[\"easylist\",\"user-filters\"]"
        let whitelist = "[\"www.nytimes.com\",\"chrome-extension-scheme\"]"
        let storage = [
            "selectedFilterLists": selected,
            "cache/easylist": cache,
            "user-filters": "\"||user.example^\"",
            "netWhitelist": whitelist
        ]
        let set = try #require(UBOFilterSource.makeSet(
            profileID: UUID(),
            extensionID: "ubo",
            packageRoot: root,
            storage: storage,
            capabilities: caps,
            compilerVersion: 1
        ))
        #expect(set.lists.map(\.name) == ["easylist"])
        #expect(set.lists[0].text == "||from.cache^\n")
        #expect(set.userFilters == "||user.example^")
        #expect(set.whitelist == ["chrome-extension-scheme", "www.nytimes.com"])
        #expect(!set.listTexts.joined().contains("annoyance"))

        let defaults = try #require(UBOFilterSource.makeSet(
            profileID: UUID(),
            extensionID: "ubo",
            packageRoot: root,
            storage: [:],
            capabilities: caps,
            compilerVersion: 1
        ))
        #expect(defaults.lists.map(\.name) == ["easylist"])
        #expect(defaults.lists[0].text.contains("from.package"))
        #expect(defaults.missing == ["regional"])
    }

    @Test func compilesAContentRuleListAndProbesTriggers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ubo-rules-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let store = WKContentRuleListStore(url: root) else {
            Issue.record("WKContentRuleListStore(url:) returned nil")
            return
        }
        let rules = FilterCompiler.translateLine("||ad.doubleclick.net^", capabilities: caps)
        let json = try #require(ContentRuleJSON.encode(rules))
        let compiled = try await store.compileContentRuleList(forIdentifier: "mb-test-doubleclick", encodedContentRuleList: json)
        #expect(compiled != nil)
        let probed = await WebKitRuleProbe.probe(store: store)
        #expect(probed.starredDomain)
    }

    @Test func countsARealEasyListWhenPresent() {
        let root = URL(fileURLWithPath: "/tmp/ubo-chromium/uBlock0.chromium/assets/thirdparties/easylist/easylist.txt")
        guard let text = try? String(contentsOf: root, encoding: .utf8) else { return }
        let compilation = FilterCompiler.compile(lists: [text], userFilters: "", whitelist: ["example.com"], capabilities: caps)
        let stats = compilation.stats
        print("easylist \(stats.summary) chunks=\(compilation.chunks.count)")
        #expect(stats.converted > 40_000)
        #expect(stats.dropped["redirect", default: 0] > 0)
        #expect(compilation.chunks.allSatisfy { chunk in
            chunk.last?.tier == .whitelist && chunk.contains { $0.tier == .exception || $0.action == .block }
        })
        let playback = "https://rr3---sn.googlevideo.com/videoplayback?id=1"
        let beacon = "https://rr3---sn.googlevideo.com/generate_204"
        let hostWide = compilation.chunks.flatMap(\.self).filter { rule in
            rule.action == .block
                && rule.urlFilter != ".*"
                && domainAllows(rule, host: "rr3---sn.googlevideo.com")
                && matches(rule.urlFilter, playback)
                && matches(rule.urlFilter, beacon)
        }
        #expect(hostWide.isEmpty, "\(hostWide.prefix(3).map(\.urlFilter))")
    }

    private func one(_ line: String) throws -> ContentRule {
        let rules = FilterCompiler.translateLine(line, capabilities: caps)
        #expect(rules.count == 1, "\(line) -> \(rules.count)")
        return try #require(rules.first)
    }

    private func reason(_ line: String) -> String? {
        var stats = ContentBlockerStats()
        // Re-run through the compiler so drop reasons stay in one place.
        let compilation = FilterCompiler.compile(lists: [line], userFilters: "", whitelist: [], capabilities: caps)
        stats = compilation.stats
        return stats.dropped.keys.first { $0 != "budget" && stats.dropped[$0] != 0 }
    }

    private func domainAllows(_ rule: ContentRule, host: String) -> Bool {
        func matchesDomain(_ domain: String) -> Bool {
            let bare = domain.hasPrefix("*") ? String(domain.dropFirst()) : domain
            return host == bare || host.hasSuffix("." + bare)
        }
        if let domains = rule.ifDomain, !domains.isEmpty, !domains.contains(where: matchesDomain) {
            return false
        }
        if let domains = rule.unlessDomain, domains.contains(where: matchesDomain) {
            return false
        }
        if let tops = rule.ifTopURL, !tops.isEmpty { return false }
        return true
    }

    private func matches(_ pattern: String, _ url: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return expression.firstMatch(in: url, options: [], range: range) != nil
    }

    /// The assembler is covered through `FilterCompiler.compile`, which also parses lines.
    /// This helper feeds already-built rules by serializing a stand-in is not available,
    /// so the budget tests below call compile on synthetic filter text.
    private func assembleFixture(_ rules: [ContentRule], maxRules: Int, maxLists: Int) -> ContentRuleCompilation {
        ContentRuleCompilation(chunks: fixtureChunks(rules, maxRules: maxRules, maxLists: maxLists), stats: ContentBlockerStats())
    }

    private func fixtureChunks(_ rules: [ContentRule], maxRules: Int, maxLists: Int) -> [[ContentRule]] {
        let lines = rules.compactMap(syntheticLine).joined(separator: "\n")
        return FilterCompiler.compile(
            lists: [lines],
            userFilters: "",
            whitelist: rules.contains { $0.tier == .whitelist } ? ["news.example"] : [],
            capabilities: caps,
            maxRules: maxRules,
            maxLists: maxLists
        ).chunks
    }

    private func syntheticLine(_ rule: ContentRule) -> String? {
        switch rule.tier {
        case .normal:
            return "||\(rule.urlFilter).example^"
        case .exception:
            return "@@||\(rule.urlFilter).example^"
        case .cosmetic:
            return "##.ad"
        case .whitelist, .important, .importantException:
            return nil
        }
    }
}
