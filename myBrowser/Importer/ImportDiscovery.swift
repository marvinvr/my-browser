import Foundation

/// One browser the import sheet can offer. Paths are read off the main actor.
nonisolated struct ImportSource: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case arcSidebar
        case chromium(ChromiumBrowser)
    }

    var id: String
    var title: String
    var detail: String
    var kind: Kind
    var fileURL: URL
    /// Chromium profile name, used as the new space name.
    var profileName: String
    var symbol: String
    var color: SpaceColor
    var bundleIdentifier: String?
    var fallbackSymbol: String
    /// Arc Chromium directory basename → display name. Empty for other sources.
    var arcProfileNames: [String: String]
    var unpinnedSiteCount: Int
}

nonisolated enum ChromiumBrowser: String, CaseIterable, Sendable {
    case chrome, brave, edge, vivaldi, arc, chromium

    var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        case .chromium: "Chromium"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .arc: "company.thebrowser.Browser"
        case .chromium: "org.chromium.Chromium"
        }
    }

    var symbol: String {
        switch self {
        case .chrome: "globe"
        case .brave: "shield.fill"
        case .edge: "globe"
        case .vivaldi: "v.circle.fill"
        case .arc: "square.stack.3d.up.fill"
        case .chromium: "globe"
        }
    }

    var color: SpaceColor {
        switch self {
        case .chrome: .blue
        case .brave: .orange
        case .edge: .teal
        case .vivaldi: .red
        case .arc: .purple
        case .chromium: .gray
        }
    }

    /// Path under Application Support.
    var supportComponents: [String] {
        switch self {
        case .chrome: ["Google", "Chrome"]
        case .brave: ["BraveSoftware", "Brave-Browser"]
        case .edge: ["Microsoft Edge"]
        case .vivaldi: ["Vivaldi"]
        case .arc: ["Arc", "User Data"]
        case .chromium: ["Chromium"]
        }
    }
}

nonisolated enum ImportDiscovery {
    /// `MYBROWSER_IMPORT_ROOT` replaces `~/Library/Application Support` for tests and snapshots.
    static func applicationSupportDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["MYBROWSER_IMPORT_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL.applicationSupportDirectory
    }

    static func sources(in applicationSupport: URL) -> [ImportSource] {
        var found: [ImportSource] = []
        if let arc = arcSidebar(in: applicationSupport) {
            found.append(arc)
        }
        for browser in ChromiumBrowser.allCases {
            found.append(contentsOf: chromiumProfiles(browser, in: applicationSupport))
        }
        return found
    }

    private static func arcSidebar(in root: URL) -> ImportSource? {
        let file = root.appending(path: "Arc", directoryHint: .isDirectory)
            .appending(path: "StorableSidebar.json", directoryHint: .notDirectory)
        guard fileExists(file), let data = try? Data(contentsOf: file) else { return nil }
        let names = profileNames(localState: arcUserData(in: root).appending(path: "Local State"))
        guard let read = ArcSidebarParser.read(data: data, includeUnpinned: false, profileNames: names),
              !read.plan.spaces.isEmpty else { return nil }
        let plan = read.plan
        var detail = "\(plan.spaces.count) \(plan.spaces.count == 1 ? "space" : "spaces")"
        detail += " · \(plan.pinnedSiteCount) pinned"
        if plan.favoriteSiteCount > 0 {
            detail += " · \(plan.favoriteSiteCount) \(plan.favoriteSiteCount == 1 ? "favorite" : "favorites")"
        }
        if read.unpinnedSiteCount > 0 {
            detail += " · \(read.unpinnedSiteCount) unpinned"
        }
        return ImportSource(
            id: "arc-sidebar",
            title: "Arc",
            detail: detail,
            kind: .arcSidebar,
            fileURL: file,
            profileName: "Arc",
            symbol: "square.stack.3d.up.fill",
            color: .purple,
            bundleIdentifier: ChromiumBrowser.arc.bundleIdentifier,
            fallbackSymbol: "square.stack.3d.up.fill",
            arcProfileNames: names,
            unpinnedSiteCount: read.unpinnedSiteCount
        )
    }

    private static func chromiumProfiles(_ browser: ChromiumBrowser, in root: URL) -> [ImportSource] {
        let directory = browser.supportComponents.reduce(root) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
        guard directoryExists(directory) else { return [] }
        let names = profileNames(localState: directory.appending(path: "Local State"))
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let profiles = directories
            .filter { directoryExists($0) && isUserProfile($0.lastPathComponent, known: names) }
            .filter { fileExists($0.appending(path: "Bookmarks")) }
            .sorted { profileOrder($0.lastPathComponent) < profileOrder($1.lastPathComponent) }

        return profiles.compactMap { profile in
            let folder = profile.lastPathComponent
            let bookmarks = profile.appending(path: "Bookmarks")
            guard let data = try? Data(contentsOf: bookmarks),
                  let plan = ChromiumBookmarkParser.plan(
                    data: data,
                    options: ChromiumBookmarkParser.Options(spaceName: folder, bookmarkBarAsFolder: true)
                  ),
                  plan.pinnedSiteCount > 0 else { return nil }
            let profileName = names[folder] ?? folder
            let title = "\(browser.displayName) — \(profileName)"
            return ImportSource(
                id: "\(browser.rawValue):\(folder)",
                title: title,
                detail: "\(plan.pinnedSiteCount) \(plan.pinnedSiteCount == 1 ? "bookmark" : "bookmarks")",
                kind: .chromium(browser),
                fileURL: bookmarks,
                profileName: profileName,
                symbol: "bookmark.fill",
                color: browser.color,
                bundleIdentifier: browser.bundleIdentifier,
                fallbackSymbol: browser.symbol,
                arcProfileNames: [:],
                unpinnedSiteCount: 0
            )
        }
    }

    private static func arcUserData(in root: URL) -> URL {
        ChromiumBrowser.arc.supportComponents.reduce(root) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
    }

    private static func isUserProfile(_ name: String, known: [String: String]) -> Bool {
        if name == "Guest Profile" || name == "System Profile" { return false }
        if name == "Default" { return true }
        if name.hasPrefix("Profile ") {
            let suffix = name.dropFirst("Profile ".count)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
        return known[name] != nil
    }

    private static func profileOrder(_ name: String) -> (Int, String) {
        if name == "Default" { return (0, name) }
        if name.hasPrefix("Profile "), let number = Int(name.dropFirst("Profile ".count)) {
            return (number, name)
        }
        return (10_000, name)
    }

    /// `profile.info_cache.<directory>.name`. Emails are ignored.
    static func profileNames(localState: URL) -> [String: String] {
        guard fileExists(localState),
              let data = try? Data(contentsOf: localState),
              let root = JSONTree.object(from: data),
              let profile = JSONTree.dictionary(root["profile"]),
              let cache = JSONTree.dictionary(profile["info_cache"]) else { return [:] }
        var names: [String: String] = [:]
        for (directory, value) in cache {
            guard let info = JSONTree.dictionary(value),
                  let name = JSONTree.string(info["name"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            names[directory] = name
        }
        return names
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
