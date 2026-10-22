# myBrowser architecture

Living document. Update it when you change structure, the data model or a decision below.

## Stack

- macOS 26+, Swift 6 language mode, SwiftUI for views, AppKit where SwiftUI can't (NSWindow tweaks, WKWebView hosting, event monitors).
- Default actor isolation is **MainActor** for the app target (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency). Everything UI/WebKit/store related is main-actor. Only pure value types (models, `SortKey`, URL parsing) are `nonisolated`/`Sendable`.
- XcodeGen (`project.yml`). The `.xcodeproj` is generated and git-ignored. Folders are globbed, so adding a file only needs `xcodegen`.
- Sparkle 2.10.0 (Swift package) ships updates. The feed is `appcast.xml` on `main`.
- Not sandboxed (a browser needs downloads anywhere, Arc/Chrome import reads `~/Library`). Local Debug builds are ad-hoc signed (`CODE_SIGN_IDENTITY = -`). Developer ID releases go through `scripts/release.sh`. Bundle id `ch.marvinvr.mybrowser`. Library files stay in `~/Library/Application Support/myBrowser/` (not the bundle id).

## Folder layout

```
myBrowser/
  App/            MyBrowserApp (scene), AppCommands (menu + shortcuts), WindowConfigurator (NSWindow tweaks)
  Model/          Value types: Profile, Space, SidebarItem, SpaceColor, SortKey, SearchEngine, URLInput, URLDisplay
  Persistence/    LibraryStore (synced data), SessionStore (local window/tab session), JSONFileStorage
  Browser/        BrowserModel (per-window coordinator), BrowserTab (one WKWebView), ProfileManager, FaviconStore
  Extensions/     ExtensionManager (one WKWebExtensionController per profile), CRX/zip install, catalog
  Views/
    Shell/        MainWindowView: sidebar + content card, ContentToolbar above the page or in the sidebar
    Toolbar/      AddressField, NavigationButtons, CopyLinkButton (shared by the top bar and the sidebar address bar)
    Sidebar/      SidebarView, SpaceSwipeContainer, FavoritesGrid, PinnedTree, TabList, SpaceSwitcher, SidebarRow
    Settings/     Settings scene: General (search engine), Appearance (address bar position, Dock icon), Extensions
    Web/          WebContentView (NSViewRepresentable that swaps the selected tab's WKWebView in)
    CommandBar/   CommandBarView + CommandBarModel (results)
  Resources/      Assets.xcassets
myBrowserTests/   Swift Testing unit tests (model, SortKey, store, URL parsing)
```

## Data model

Two kinds of state:

1. **Library** (`LibraryStore`, `library.json`): profiles, spaces, sidebar items. This is the part that will sync via CloudKit in Phase 2 (except the `tabs` section, see below).
2. **Session** (`SessionStore`, `session.json`): local-only window state: selected space, selected item per space, per-tab WebKit `interactionState` (back/forward history), recently closed tabs. Never synced.

### Profile
`Profile { id: UUID, name, modifiedAt, deletedAt? }`. The profile's `id` is the identifier passed to `WKWebsiteDataStore(forIdentifier:)`, so cookies, local storage, caches etc. are isolated per profile and persist across launches. By default every new Space gets its own new Profile (1:1); the model allows several Spaces to share a Profile later (Arc does this).

### Space
`Space { id, name, symbol (SF Symbol name), color: SpaceColor, profileID, sortKey, modifiedAt, deletedAt? }`.

### SidebarItem
One flat table; the tree comes from `parentID`.

```
SidebarItem {
  id: UUID
  spaceID: UUID
  section: .favorites | .pinned | .tabs
  kind: .site | .folder
  parentID: UUID?        // folder id; only within .pinned (nested folders). nil = section root
  title: String          // user title (folders, renamed pins) or last page title
  url: URL?              // .site: the pinned "home" URL; for .tabs items the current URL
  sortKey: String        // fractional index, ordering among siblings
  isExpanded: Bool       // folders
  createdAt, modifiedAt: Date
  deletedAt: Date?       // tombstone
}
```

- **favorites**: pinned sites shown as the favicon grid at the top of the sidebar. Sites only, no folders, flat.
- **pinned**: pinned sites and (nested) folders below the grid.
- **tabs**: today's unpinned tabs. Sites only, flat. Every open unpinned tab *is* a `.tabs` item, which is how tabs survive relaunch.

A pinned/favorite site keeps its `url` as the home URL even when its live tab navigates elsewhere (Arc behaviour). Closing a pinned tab unloads its web view, the item stays.

### Tabs (runtime)
`BrowserTab` (`@Observable`, main actor) is the live counterpart of a site item: `tab.id == item.id`. It owns at most one `WKWebView`, created lazily on first selection, so restored tabs cost nothing until used. It exposes `title`, `url`, `favicon`, `isLoading`, `estimatedProgress`, `canGoBack/Forward`, `themeColor`, and `goBack/goForward/reload/stop/load`. `themeColor` is the page tint: WebKit's `themeColor` when that colour is opaque, else `underPageBackgroundColor`, else a sample of the top of the page. On creation it restores `interactionState` from the session store if present (back/forward history survives relaunch).

`BrowserModel.tabs: [UUID: BrowserTab]` holds the live tabs. An item without a `BrowserTab` is "not loaded". Selecting it creates one.

### Ordering keys
`sortKey` is a fractional index string (`SortKey.between(a, b)`, base-62 digits, lexicographic compare). Inserting/moving only rewrites the moved record, which keeps CloudKit conflicts local to one record. Ties (two devices inserting at the same spot) are broken by `id`.

### Tombstones
Deleting a Profile/Space/favorites/pinned item sets `deletedAt` (and `modifiedAt`) instead of removing the record; everything reading the store filters tombstones. Deleting a folder tombstones its descendants. Tombstones are purged after 30 days (Phase 2: only once CloudKit has acknowledged the deletion). `.tabs` items are local-only and hard-deleted.

### Sync readiness (Phase 2)
- Every record has a stable UUID → `CKRecord.ID(recordName: uuid)`, record types `Profile`, `Space`, `SidebarItem`. Zone: one custom zone `Library`.
- `modifiedAt` per record for last-writer-wins; finer field-level merge can come later.
- `.tabs` items are excluded from sync.
- Phase 2 adds a separate `sync-state.json` (CKSyncEngine state serialization + encoded system fields per record). `LibraryStore` emits change notifications (`onChange(ids)`) that the sync layer will turn into pending record zone changes.
- Decision: **plain Codable + JSON file, not SwiftData.** The data set is small (hundreds of records), JSON is easy to inspect/import/export, and CKSyncEngine wants explicit control over records and change tracking, which SwiftData hides.

### Persistence
`~/Library/Application Support/myBrowser/` (`library.json`, `session.json`, `Favicons/`). Writes are debounced (~0.5 s) and atomic; also flushed on `applicationWillTerminate`. A `schemaVersion` field allows migrations. Tests use a temp directory.

## Window / scene structure

- Phase 1: one main window (`Window` scene, id `main`) with one `BrowserModel`. `LibraryStore` and `SessionStore` are app-level singletons owned by the app and injected. Multiple windows (each its own `BrowserModel` sharing the library) come later.
- Settings (`Settings` scene, ⌘,): **General** — default search engine (`SearchEngine.defaultsKey`). **Appearance** — address bar position (`AddressBarPosition.defaultsKey`: `top` default, or `sidebar`) and the Dock icon (`AppIconVariant.defaultsKey`: `light` default, or `dark`). **Extensions** — installed web extensions, per-profile enablement, install from a file or the Chrome Web Store. General and Appearance are `@AppStorage` over `UserDefaults`. Grouped `Form`.
- Window: hidden title bar, full-size content view, transparent title bar; the traffic lights sit over the sidebar like Arc. `WindowConfigurator` (an `NSViewRepresentable` that grabs `view.window`) applies the AppKit tweaks and moves `standardWindowButton`s so their vertical centre matches the toolbar. It re-applies that position on resize and when leaving fullscreen (AppKit resets the buttons). While fullscreen is active the system owns the buttons.
- Layout (`MainWindowView`): full-height sidebar on the left (behind-window vibrancy), web content on the right as a rounded card inset by a few points. The sidebar toggles with ⌘S (View menu "Hide Sidebar" / "Show Sidebar", plus a `sidebar.left` button). When hidden, the card fills the window edge to edge: no inset, no shadow, so the sidebar material does not leave a frame. Collapse and the address-bar setting share one spring (`SidebarMotion.sidebar`). The traffic-light centre stays on `SidebarMetrics.chromeCenterFromTop` in both modes, so the lights do not jump.
- Toolbar (`ContentToolbar`): `NavigationButtons` (back, forward, reload/stop) and `AddressField` (with `CopyLinkButton`) read `BrowserModel` from the environment and take an optional `ToolbarChrome`. Extension action buttons sit at the trailing end of the content toolbar, and on their own row under the address field when that field is in the sidebar. Up to four icons show; the rest are in a puzzle-piece menu. The resting field shows `URLDisplay`: host without scheme or `www.`, up to three path segments, no query or fragment. Clicking it (or Cmd+L) opens the command bar in edit-current mode with the full URL selected. ⌘R is handled only by `KeyMonitor` (Ctrl+R does nothing; key repeat does not reload again). ⌘⇧C copies the current URL. A thin progress line runs under the bar while the page loads.
  - **Top** (default): the bar sits across the top of the content card and crossfades (~0.25s) to `BrowserTab.themeColor`. A transparent or neon colour keeps the window background. The field fill and label colours are derived from that tint so the text stays legible. The sidebar's top row is only the traffic lights and the sidebar-toggle button. When the sidebar is hidden, the toolbar keeps ~74pt of leading space so the controls clear the traffic lights, and a matching top spacer keeps that row on the same line as when the card was inset.
  - **Sidebar**: the same controls sit on the traffic-light row (navigation to the right of the lights, address field below). Their chrome stays untinted, because the page colour is not painted on the sidebar. The content card has no toolbar and keeps its normal inset. When the sidebar is hidden, the content toolbar is shown anyway so the URL stays visible.
- Sidebar rows use a flat highlight (soft white in light mode, white at about 12% in dark mode) with the system label color, so the title stays readable. They do not use `glassEffect`. Space icons share one size; the selected space is a small rounded chip tinted with the space color at about 16–18%, and the symbol is drawn in the space color.
- Command bar: a SwiftUI overlay centred over the window (glass panel), not a separate NSPanel. It opens with a short spring (~0.18s) and closes faster.

## WebKit management

- `ProfileManager` caches one `WKWebsiteDataStore(forIdentifier: profile.id)` per profile and builds a `WKWebViewConfiguration` per tab from it (shared data store ⇒ shared cookies within a Space). The same configuration receives that profile's `WKWebExtensionController`.
- `WebContentView` is an `NSViewRepresentable` around a plain container `NSView`; when the selected tab changes it removes the old `WKWebView` and adds the new one as a subview (pinned to edges). Web views are never recreated on selection changes, so page state is kept.
- Space switching swaps the sidebar contents and selects that space's last selected item; live tabs of other spaces stay loaded (memory pressure handling / tab unloading is Phase 2+).
- `target=_blank` / `window.open` / Cmd-click: `WKUIDelegate.createWebView` → new `.tabs` item in the same space (Phase 1 opens in a new tab and selects it; Cmd-click opens in background).
- Back/forward: `allowsBackForwardNavigationGestures = true` (Safari-style two-finger swipe on the page). Decision: **page swipe = back/forward; swipes on the sidebar switch spaces**. `SpaceSwipeContainer` claims a horizontal trackpad swipe on the space column only (`SpaceSwipeTracker`); vertical list scrolling and the web view are left alone.
- Favicons: `FaviconStore` downloads `/favicon.ico` or the page's `<link rel=icon>` (via JS after load) and caches PNGs per host in `Favicons/`. Not synced.

## Web extensions

- `ExtensionManager` is app-level. It keeps one `WKWebExtensionController` per profile, created with `WKWebExtensionController.Configuration(identifier: profile.id)`, so an extension's storage stays with that profile. Enabling an extension in one profile leaves other profiles' spaces alone.
- Installed packages are unpacked under `~/Library/Application Support/myBrowser/Extensions/<extension-id>/`. `extensions.json` in that folder records id, name, version, source, the profile ids where it is enabled, and the granted and denied permissions and match patterns.
- Install sources: an unpacked folder, `.zip`, Firefox `.xpi`, Chrome `.crx` (CRX2 and CRX3; the header is stripped and the ZIP is unpacked with `/usr/bin/ditto`), and a Chrome Web Store URL or id. Manifest V2 and V3 are accepted. The catalog loads at launch; only extensions enabled for a profile are loaded into that profile's controller.
- `BrowserTab` adopts `WKWebExtensionTab` (`Browser/BrowserTab+Extension.swift`). The main window is one `WKWebExtensionWindow`. Open, activate, close, and property changes are forwarded to the controller. An extension that opens a tab goes through `BrowserModel.openTabForExtension`, which returns the live tab. Extension pages (options, extension URLs) use that extension context's `webViewConfiguration`.
- A click calls `performAction(for:)`. When the action presents a popup, the controller delegate shows `action.popupPopover` anchored to the toolbar button. Permission requests are an Allow / Don't Allow sheet. The choice is written into `extensions.json` and applied with `setPermissionStatus` before the context loads.
- Enabling an extension that injects scripts reloads that profile's open http(s) pages so the scripts run. Launching the app loads the extension without reloading pages that are already open.

## Command bar

- Cmd+T: new tab mode (empty field). Cmd+L: edit current URL (prefilled, selected); Enter navigates the current tab.
- Results: "Open URL" when input looks like a URL, "Search <engine>" otherwise, plus matching open tabs / pinned sites in the current space (title or URL contains the query) → switch to them.
- `URLInput.resolve(_:)` decides URL vs search: explicit scheme, `localhost[:port]`, IPs, or `something.tld` without spaces ⇒ URL (https assumed); everything else ⇒ search.
- Default search engine: **Google** (enum `SearchEngine`: google, duckDuckGo, kagi, bing, ecosia). The choice is Settings → General, stored in `UserDefaults` under `SearchEngine.defaultsKey`.

## Keyboard shortcuts (Phase 1)

| Shortcut | Action |
|---|---|
| Cmd+T | Command bar, new tab |
| Cmd+L | Command bar, edit current URL |
| Cmd+W | Close tab (pinned/favorite: unload; tabs: delete) |
| Cmd+Shift+T | Reopen last closed tab |
| Cmd+1…8 | Select n-th item in sidebar order (favorites, pinned (expanded), tabs); Cmd+9 = last |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous item in sidebar order |
| Cmd+Opt+→ / ← | Next / previous space |
| Cmd+[ / Cmd+] | Back / forward |
| Cmd+R | Reload (`KeyMonitor` only; Ctrl+R does nothing) |
| Cmd+Shift+C | Copy link |
| Cmd+S | Hide / show sidebar |
| Cmd+D | Pin / unpin current tab |
| Esc | Close command bar / stop loading |

## Decisions log
- 2026-10-22: JSON + Codable store instead of SwiftData (see Sync readiness).
- 2026-10-22: one Profile per Space by default; model allows sharing.
- 2026-10-22: not sandboxed.
- 2026-10-22: default search engine Google, chosen in Settings → General.
- 2026-10-22: page two-finger swipe = back/forward, sidebar swipe = spaces. Sidebar swipe commits past 30% of the column or on a flick, and rubber-bands on the first and last space.
- 2026-10-22: single window in Phase 1.
- 2026-10-22: address field and back/forward/reload live in a toolbar above the page by default. Settings → Appearance can move the same controls to the top of the sidebar. Tabs stay in the sidebar. Sidebar selection is a flat fill, not glass.
- 2026-10-22: the content toolbar tints from the page theme colour and shows a formatted URL. ⌘⇧C copies the link.
- 2026-10-22: collapsed sidebar draws the content card edge to edge. Traffic lights stay vertically centred on the toolbar in both modes.
- 2026-10-22: bundle id `ch.marvinvr.mybrowser`; Sparkle feed on `main`; releases via `scripts/release.sh`.
- 2026-10-23: Dock icon is the light AppIcon unless Settings → Appearance picks dark. Applied at launch and on change with `NSApp.applicationIconImage` only. `NSWorkspace.setIcon` is not used; it modifies the signed bundle and breaks the code signature and Sparkle updates.
- 2026-10-23: web extensions use `WKWebExtensionController`, one controller per profile id. Packages are unpacked under `Application Support/myBrowser/Extensions`.
