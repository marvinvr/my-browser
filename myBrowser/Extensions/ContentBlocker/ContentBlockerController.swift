import Foundation
import os
import WebKit

nonisolated enum ContentBlockerCompiler {
    static let version = 1
}

private let contentBlockerLog = Logger(subsystem: "ch.marvinvr.mybrowser", category: "content-blocker")

/// Compiles the enabled uBlock Origin lists for each profile into `WKContentRuleList`s.
///
/// Translation runs off the main actor. WebKit's compiler stays on the main actor.
/// A hash of the filter set skips that work until a list, a user filter, or the
/// per-site whitelist changes. The popup power button writes the whitelist.
final class ContentBlockerController {
    let extensionsDirectory: URL

    var recordsProvider: () -> [ExtensionRecord] = { [] }

    private weak var model: BrowserModel?
    private var store: WKContentRuleListStore?
    private var capabilitiesCache: WebKitRuleCapabilities?
    private var generations: [UUID: Generation] = [:]
    private var appliedHash: [UUID: String] = [:]
    private var installedHash: [ObjectIdentifier: String] = [:]
    private var installedLists: [ObjectIdentifier: [WKContentRuleList]] = [:]
    private var jobs: [UUID: ExtensionRecord] = [:]
    private var compiling: Set<UUID> = []
    private var queued: Set<UUID> = []
    private var watched: [UUID: String] = [:]
    private var lastStamp: [UUID: TimeInterval] = [:]
    private var debounce: [UUID: Int] = [:]
    private var polling = false

    private struct Generation {
        var hash: String
        var lists: [WKContentRuleList]
        var identifiers: [String]
        var stats: ContentBlockerStats
    }

    private struct CompiledList {
        var id: String
        var list: WKContentRuleList
    }

    private struct Sidecar: Codable {
        var compilerVersion: Int
        var hash: String
        var identifiers: [String]
        var stats: ContentBlockerStats
        var capabilities: WebKitRuleCapabilities
        var missing: [String]
        var packageFallbacks: [String]
    }

    init(extensionsDirectory: URL) {
        self.extensionsDirectory = extensionsDirectory
    }

    func attach(_ model: BrowserModel) {
        self.model = model
        model.profiles.prepareConfiguration = { [weak self] configuration, profileID in
            self?.install(into: configuration, profileID: profileID)
        }
    }

    /// Starts a compile for every profile where full uBlock Origin is enabled.
    func refresh() {
        var active: [UUID: ExtensionRecord] = [:]
        for record in recordsProvider() where UBOFilterSource.isFullUBO(record, extensionsDirectory: extensionsDirectory) {
            for profileID in record.enabledProfileIDs {
                active[profileID] = record
            }
        }
        for profileID in Set(generations.keys).union(watched.keys) where active[profileID] == nil {
            clear(profileID)
        }
        for (profileID, record) in active {
            watch(profileID, extensionID: record.id)
            schedule(profileID, record: record)
        }
        ensurePoll()
    }

    func install(into configuration: WKWebViewConfiguration, profileID: UUID) {
        let controller = configuration.userContentController
        let key = ObjectIdentifier(controller)
        let hash = generations[profileID]?.hash ?? ""
        if installedHash[key] == hash { return }
        if let previous = installedLists[key] {
            for list in previous {
                controller.remove(list)
            }
        }
        let lists = generations[profileID]?.lists ?? []
        for list in lists {
            controller.add(list)
        }
        installedHash[key] = hash
        installedLists[key] = lists
    }

    // MARK: Schedule

    private func schedule(_ profileID: UUID, record: ExtensionRecord) {
        jobs[profileID] = record
        if compiling.contains(profileID) {
            queued.insert(profileID)
            return
        }
        compiling.insert(profileID)
        Task {
            await self.compile(profileID)
            self.compiling.remove(profileID)
            if self.queued.remove(profileID) != nil, let record = self.jobs[profileID] {
                self.schedule(profileID, record: record)
            }
        }
    }

    private func compile(_ profileID: UUID) async {
        guard let record = jobs[profileID] else { return }
        let caps = await currentCapabilities()
        let packageRoot = extensionsDirectory.appending(path: record.directory, directoryHint: .isDirectory)
        let extensionID = record.id
        let version = ContentBlockerCompiler.version
        let started = Date()
        let set = await Task.detached(priority: .utility) {
            let storage = UBOFilterSource.readStorage(profileID: profileID, extensionID: extensionID)
            return UBOFilterSource.makeSet(
                profileID: profileID,
                extensionID: extensionID,
                packageRoot: packageRoot,
                storage: storage,
                capabilities: caps,
                compilerVersion: version
            )
        }.value
        guard let set else {
            contentBlockerLog.error("uBlock Origin package is missing assets.json")
            return
        }
        if generations[profileID]?.hash == set.hash {
            apply(profileID, reloadIfChanged: false)
            return
        }
        if let cached = await loadCached(set, capabilities: caps) {
            generations[profileID] = cached
            let seconds = Date().timeIntervalSince(started)
            writeReport(set: set, stats: cached.stats, seconds: seconds, cached: true, capabilities: caps)
            apply(profileID, reloadIfChanged: true)
            return
        }
        let listTexts = set.listTexts
        let userFilters = set.userFilters
        let whitelist = set.whitelist
        var compilation = await Task.detached(priority: .utility) {
            FilterCompiler.compile(
                lists: listTexts,
                userFilters: userFilters,
                whitelist: whitelist,
                capabilities: caps
            )
        }.value
        for _ in set.missing { compilation.stats.drop("missing-list") }
        let compiled = await compileChunks(compilation.chunks, profileID: profileID, hash: set.hash, stats: &compilation.stats)
        let seconds = Date().timeIntervalSince(started)
        compilation.stats.compileSeconds = seconds
        let generation = Generation(
            hash: set.hash,
            lists: compiled.map(\.list),
            identifiers: compiled.map(\.id),
            stats: compilation.stats
        )
        generations[profileID] = generation
        saveSidecar(set: set, generation: generation, capabilities: caps)
        await removeStale(profileID: profileID, keeping: Set(generation.identifiers))
        writeReport(set: set, stats: compilation.stats, seconds: seconds, cached: false, capabilities: caps)
        apply(profileID, reloadIfChanged: true)
    }

    private func apply(_ profileID: UUID, reloadIfChanged: Bool) {
        let hash = generations[profileID]?.hash
        let changed = appliedHash[profileID] != hash
        for webView in webViews(profileID) {
            install(into: webView.configuration, profileID: profileID)
        }
        if let auxiliary = model?.downloads.existingAuxiliaryWebView(profileID: profileID) {
            install(into: auxiliary.configuration, profileID: profileID)
        }
        appliedHash[profileID] = hash
        guard reloadIfChanged, changed, hash != nil else { return }
        model?.reloadWebTabs(in: profileID)
    }

    private func clear(_ profileID: UUID) {
        let hadLists = generations[profileID] != nil
        generations[profileID] = nil
        jobs[profileID] = nil
        watched[profileID] = nil
        lastStamp[profileID] = nil
        for webView in webViews(profileID) {
            install(into: webView.configuration, profileID: profileID)
        }
        if hadLists {
            appliedHash[profileID] = nil
            model?.reloadWebTabs(in: profileID)
            Task { await self.removeStale(profileID: profileID, keeping: []) }
        }
    }

    private func webViews(_ profileID: UUID) -> [WKWebView] {
        guard let model else { return [] }
        return model.tabs.values.compactMap { tab in
            guard tab.profileID == profileID else { return nil }
            return tab.webView
        }
    }

    // MARK: WebKit compile

    private func compileChunks(
        _ chunks: [[ContentRule]],
        profileID: UUID,
        hash: String,
        stats: inout ContentBlockerStats
    ) async -> [CompiledList] {
        var counter = 0
        var compiled: [CompiledList] = []
        var failures = 0
        for chunk in chunks {
            let tail = chunk.filter { $0.tier != .normal && $0.tier != .cosmetic }
            let body = chunk.filter { $0.tier == .normal || $0.tier == .cosmetic }
            let piece = await compilePiece(
                body: body,
                tail: tail,
                profileID: profileID,
                hash: hash,
                counter: &counter,
                stats: &stats,
                failures: &failures
            )
            compiled.append(contentsOf: piece)
        }
        stats.chunks = compiled.count
        stats.emitted = compiled.isEmpty ? 0 : stats.emitted
        return compiled
    }

    private func compilePiece(
        body: [ContentRule],
        tail: [ContentRule],
        profileID: UUID,
        hash: String,
        counter: inout Int,
        stats: inout ContentBlockerStats,
        failures: inout Int
    ) async -> [CompiledList] {
        let rules = body + tail
        guard !rules.isEmpty else { return [] }
        if failures > 48 {
            stats.drop("compile", rules.count)
            return []
        }
        let identifier = nextIdentifier(profileID: profileID, hash: hash, counter: &counter)
        let encoded = await Task.detached(priority: .utility) {
            ContentRuleJSON.encode(rules)
        }.value
        guard let encoded else {
            stats.drop("compile", rules.count)
            return []
        }
        guard let store = ruleStore() else {
            stats.drop("compile", rules.count)
            return []
        }
        do {
            guard let list = try await store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encoded
            ) else {
                stats.drop("compile", rules.count)
                return []
            }
            return [CompiledList(id: identifier, list: list)]
        } catch {
            let nsError = error as NSError
            contentBlockerLog.error(
                "compile \(identifier, privacy: .public) rules=\(rules.count) \(nsError.domain, privacy: .public) \(nsError.code) \(nsError.localizedDescription, privacy: .public)"
            )
            try? await store.removeContentRuleList(forIdentifier: identifier)
            if body.count > 1 {
                let middle = body.count / 2
                let left = await compilePiece(
                    body: Array(body[..<middle]),
                    tail: tail,
                    profileID: profileID,
                    hash: hash,
                    counter: &counter,
                    stats: &stats,
                    failures: &failures
                )
                let right = await compilePiece(
                    body: Array(body[middle...]),
                    tail: tail,
                    profileID: profileID,
                    hash: hash,
                    counter: &counter,
                    stats: &stats,
                    failures: &failures
                )
                return left + right
            }
            if body.count == 1 {
                failures += 1
                stats.drop("compile")
                return await compilePiece(
                    body: [],
                    tail: tail,
                    profileID: profileID,
                    hash: hash,
                    counter: &counter,
                    stats: &stats,
                    failures: &failures
                )
            }
            if tail.count <= 1 {
                failures += 1
                stats.drop("compile", tail.count)
                return []
            }
            let middle = tail.count / 2
            let left = await compilePiece(
                body: [],
                tail: Array(tail[..<middle]),
                profileID: profileID,
                hash: hash,
                counter: &counter,
                stats: &stats,
                failures: &failures
            )
            let right = await compilePiece(
                body: [],
                tail: Array(tail[middle...]),
                profileID: profileID,
                hash: hash,
                counter: &counter,
                stats: &stats,
                failures: &failures
            )
            return left + right
        }
    }

    private func nextIdentifier(profileID: UUID, hash: String, counter: inout Int) -> String {
        let index = counter
        counter += 1
        let profile = profileID.uuidString.prefix(8).lowercased()
        let digest = hash.prefix(12)
        return "mb-ubo-\(profile)-\(digest)-\(index)"
    }

    private func ruleStore() -> WKContentRuleListStore? {
        if let store { return store }
        let url = libraryDirectory.appending(path: "ContentBlocker/store", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let created = WKContentRuleListStore(url: url) {
            store = created
            return created
        }
        if let fallback = WKContentRuleListStore.default() {
            store = fallback
            return fallback
        }
        return nil
    }

    private func currentCapabilities() async -> WebKitRuleCapabilities {
        if let capabilitiesCache { return capabilitiesCache }
        let url = libraryDirectory.appending(path: "ContentBlocker/capabilities-v\(ContentBlockerCompiler.version).json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(WebKitRuleCapabilities.self, from: data) {
            capabilitiesCache = stored
            return stored
        }
        guard let store = ruleStore() else { return .assumed }
        let probed = await WebKitRuleProbe.probe(store: store)
        capabilitiesCache = probed
        if let data = try? JSONEncoder().encode(probed) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        contentBlockerLog.info("probe \(probed.token, privacy: .public)")
        return probed
    }

    // MARK: Cache

    private var libraryDirectory: URL {
        extensionsDirectory.deletingLastPathComponent()
    }

    private func sidecarURL(_ profileID: UUID) -> URL {
        libraryDirectory.appending(path: "ContentBlocker/profiles/\(profileID.uuidString).json")
    }

    private func loadCached(_ set: UBOFilterSet, capabilities: WebKitRuleCapabilities) async -> Generation? {
        guard let data = try? Data(contentsOf: sidecarURL(set.profileID)),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
              sidecar.compilerVersion == ContentBlockerCompiler.version,
              sidecar.hash == set.hash,
              sidecar.capabilities == capabilities,
              !sidecar.identifiers.isEmpty else { return nil }
        var lists: [WKContentRuleList] = []
        for identifier in sidecar.identifiers {
            do {
                guard let store = ruleStore(),
                      let list = try await store.contentRuleList(forIdentifier: identifier) else { return nil }
                lists.append(list)
            } catch {
                return nil
            }
        }
        return Generation(hash: set.hash, lists: lists, identifiers: sidecar.identifiers, stats: sidecar.stats)
    }

    private func saveSidecar(set: UBOFilterSet, generation: Generation, capabilities: WebKitRuleCapabilities) {
        let sidecar = Sidecar(
            compilerVersion: ContentBlockerCompiler.version,
            hash: set.hash,
            identifiers: generation.identifiers,
            stats: generation.stats,
            capabilities: capabilities,
            missing: set.missing,
            packageFallbacks: set.packageFallbacks
        )
        let url = sidecarURL(set.profileID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func removeStale(profileID: UUID, keeping: Set<String>) async {
        guard let store = ruleStore() else { return }
        let prefix = "mb-ubo-\(profileID.uuidString.prefix(8).lowercased())-"
        let identifiers = (try? await store.availableIdentifiers()) ?? []
        for identifier in identifiers where identifier.hasPrefix(prefix) && !keeping.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    // MARK: Storage changes

    private func watch(_ profileID: UUID, extensionID: String) {
        watched[profileID] = extensionID
        if lastStamp[profileID] == nil {
            lastStamp[profileID] = stamp(profileID, extensionID: extensionID)
        }
    }

    private func ensurePoll() {
        guard !polling else { return }
        polling = true
        Task { await self.pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            for (profileID, extensionID) in watched {
                let now = stamp(profileID, extensionID: extensionID)
                guard now != lastStamp[profileID] else { continue }
                lastStamp[profileID] = now
                noteStorageChange(profileID)
            }
        }
    }

    private func noteStorageChange(_ profileID: UUID) {
        debounce[profileID, default: 0] += 1
        let generation = debounce[profileID] ?? 0
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard self.debounce[profileID] == generation, let record = self.jobs[profileID] else { return }
            self.schedule(profileID, record: record)
        }
    }

    private func stamp(_ profileID: UUID, extensionID: String) -> TimeInterval {
        let database = UBOFilterSource.storageDatabaseURL(profileID: profileID, extensionID: extensionID)
        return modified(database) + modified(URL(fileURLWithPath: database.path + "-wal"))
    }

    private func modified(_ url: URL) -> TimeInterval {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    // MARK: Report

    private func writeReport(
        set: UBOFilterSet,
        stats: ContentBlockerStats,
        seconds: TimeInterval,
        cached: Bool,
        capabilities: WebKitRuleCapabilities
    ) {
        let text = [
            stats.summary,
            "seconds=\(String(format: "%.2f", seconds))",
            "cached=\(cached)",
            "hash=\(set.hash)",
            "capabilities=\(capabilities.token)",
            "lists=\(set.lists.map(\.name).joined(separator: ","))",
            "missing=\(set.missing.joined(separator: ","))",
            "fallback=\(set.packageFallbacks.joined(separator: ","))",
            "whitelist=\(set.whitelist.count)",
            "profile=\(set.profileID.uuidString)"
        ].joined(separator: "\n")
        contentBlockerLog.info("\(text, privacy: .public)")
        let evidence = URL(fileURLWithPath: "/tmp/my-browser-shots/ubo-bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try? text.write(to: evidence.appending(path: "content-blocker.txt"), atomically: true, encoding: .utf8)
        if let library = ProcessInfo.processInfo.environment["MYBROWSER_DEBUG_LIBRARY"], !library.isEmpty {
            let url = URL(fileURLWithPath: library, isDirectory: true).appending(path: "content-blocker.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum WebKitRuleProbe {
    static func probe(store: WKContentRuleListStore) async -> WebKitRuleCapabilities {
        WebKitRuleCapabilities(
            loadContext: await compiles(store, #"[{"trigger":{"url-filter":".*","load-context":["top-frame"]},"action":{"type":"block"}}]"#),
            ifTopURL: await compiles(store, #"[{"trigger":{"url-filter":".*","if-top-url":["^https://example\\.com/"]},"action":{"type":"block"}}]"#),
            websocket: await compiles(store, #"[{"trigger":{"url-filter":".*","resource-type":["websocket"]},"action":{"type":"block"}}]"#),
            starredDomain: await compiles(store, #"[{"trigger":{"url-filter":".*","if-domain":["*example.com"]},"action":{"type":"block"}}]"#),
            ifAndUnlessDomain: await compiles(store, #"[{"trigger":{"url-filter":".*","if-domain":["*example.com"],"unless-domain":["*ads.example.com"]},"action":{"type":"block"}}]"#)
        )
    }

    private static func compiles(_ store: WKContentRuleListStore, _ json: String) async -> Bool {
        let identifier = "mb-probe-\(UUID().uuidString.prefix(8))"
        do {
            guard try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) != nil else {
                try? await store.removeContentRuleList(forIdentifier: identifier)
                return false
            }
            try? await store.removeContentRuleList(forIdentifier: identifier)
            return true
        } catch {
            try? await store.removeContentRuleList(forIdentifier: identifier)
            return false
        }
    }
}
