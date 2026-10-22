# myBrowser architecture

Living document. Update it when you change structure, the data model or a decision below.

## Stack

- macOS 26+, Swift 6 language mode, SwiftUI for views, AppKit where SwiftUI can't (NSWindow tweaks, WKWebView hosting, event monitors).
- Default actor isolation is **MainActor** for the app target (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency). Everything UI/WebKit/store related is main-actor. Only pure value types (models, `SortKey`, URL parsing) are `nonisolated`/`Sendable`.
- XcodeGen (`project.yml`). The `.xcodeproj` is generated and git-ignored. Folders are globbed, so adding a file only needs `xcodegen`.
- No third-party dependencies in Phase 1.
- Not sandboxed (a browser needs downloads anywhere, Arc/Chrome import reads `~/Library`). Ad-hoc signed locally (`CODE_SIGN_IDENTITY = -`). Developer ID + iCloud entitlements later.

## Folder layout

```
myBrowser/
  App/            MyBrowserApp (scene), AppCommands (menu + shortcuts), WindowConfigurator (NSWindow tweaks)
  Model/          Value types: Profile, Space, SidebarItem, SpaceColor, SortKey, SearchEngine, URLInput
  Persistence/    LibraryStore (synced data), SessionStore (local window/tab session), JSONFileStorage
  Browser/        BrowserModel (per-window coordinator), BrowserTab (one WKWebView), ProfileManager, FaviconStore
  Views/
    Shell/        MainWindowView: sidebar + content card, ContentToolbar above the page
    Sidebar/      SidebarView, FavoritesGrid, PinnedTree, TabList, SpaceSwitcher, SidebarRow
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
`BrowserTab` (`@Observable`, main actor) is the live counterpart of a site item: `tab.id == item.id`. It owns at most one `WKWebView`, created lazily on first selection, so restored tabs cost nothing until used. It exposes `title`, `url`, `favicon`, `isLoading`, `estimatedProgress`, `canGoBack/Forward`, and `goBack/goForward/reload/stop/load`. On creation it restores `interactionState` from the session store if present (back/forward history survives relaunch).

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
- Window: hidden title bar, full-size content view, transparent title bar; the traffic lights sit over the sidebar like Arc. `WindowConfigurator` (an `NSViewRepresentable` that grabs `view.window`) applies the AppKit tweaks.
- Layout (`MainWindowView`): full-height sidebar on the left (behind-window vibrancy), web content on the right as a rounded card inset by a few points. The sidebar can be toggled (Cmd+S, like Arc); when hidden the card fills the window.
- Toolbar (`ContentToolbar`): a compact bar (~38pt) across the top of the content card, above the page. It holds back, forward, and reload/stop, plus a Liquid Glass capsule address field that shows the page host. Clicking the field (or Cmd+L) opens the command bar in edit-current mode. A thin progress line runs under the toolbar while the page loads. The sidebar's top row is only the traffic lights and a sidebar-toggle button; favorites start below it. When the sidebar is hidden, the toolbar insets its controls so they clear the traffic lights.
- Sidebar rows use a flat highlight (soft white in light mode, a lighter fill in dark mode). They do not use `glassEffect`. Space icons share one size; the selected space is a small tinted rounded chip.
- Command bar: a SwiftUI overlay centred over the window (glass panel), not a separate NSPanel. It opens with a short spring (~0.18s) and closes faster.

## WebKit management

- `ProfileManager` caches one `WKWebsiteDataStore(forIdentifier: profile.id)` per profile and builds a `WKWebViewConfiguration` per tab from it (shared data store ⇒ shared cookies within a Space).
- `WebContentView` is an `NSViewRepresentable` around a plain container `NSView`; when the selected tab changes it removes the old `WKWebView` and adds the new one as a subview (pinned to edges). Web views are never recreated on selection changes, so page state is kept.
- Space switching swaps the sidebar contents and selects that space's last selected item; live tabs of other spaces stay loaded (memory pressure handling / tab unloading is Phase 2+).
- `target=_blank` / `window.open` / Cmd-click: `WKUIDelegate.createWebView` → new `.tabs` item in the same space (Phase 1 opens in a new tab and selects it; Cmd-click opens in background).
- Back/forward: `allowsBackForwardNavigationGestures = true` (Safari-style two-finger swipe on the page). Decision: **page swipe = back/forward; swipes on the sidebar switch spaces** (Phase 2 implements the sidebar swipe).
- Favicons: `FaviconStore` downloads `/favicon.ico` or the page's `<link rel=icon>` (via JS after load) and caches PNGs per host in `Favicons/`. Not synced.

## Command bar

- Cmd+T: new tab mode (empty field). Cmd+L: edit current URL (prefilled, selected); Enter navigates the current tab.
- Results: "Open URL" when input looks like a URL, "Search <engine>" otherwise, plus matching open tabs / pinned sites in the current space (title or URL contains the query) → switch to them.
- `URLInput.resolve(_:)` decides URL vs search: explicit scheme, `localhost[:port]`, IPs, or `something.tld` without spaces ⇒ URL (https assumed); everything else ⇒ search.
- Default search engine: **Google**, user-selectable later (enum `SearchEngine`: google, duckDuckGo, kagi, bing, ecosia); stored in `UserDefaults`.

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
| Cmd+R | Reload |
| Cmd+S | Toggle sidebar |
| Cmd+D | Pin / unpin current tab |
| Esc | Close command bar / stop loading |

## Decisions log
- 2026-10-22: JSON + Codable store instead of SwiftData (see Sync readiness).
- 2026-10-22: one Profile per Space by default; model allows sharing.
- 2026-10-22: not sandboxed.
- 2026-10-22: default search engine Google (to be a setting).
- 2026-10-22: page two-finger swipe = back/forward, sidebar swipe = spaces.
- 2026-10-22: single window in Phase 1.
- 2026-10-22: address field and back/forward/reload live in a toolbar above the page. Tabs stay in the sidebar. Sidebar selection is a flat fill, not glass.
