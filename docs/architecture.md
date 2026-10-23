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
  Sync/           CKSyncEngine wrapper, record mapping, sync-state.json. Idle unless iCloud Sync is enabled.
  Browser/        BrowserModel (per-window coordinator), BrowserTab (one WKWebView), ProfileManager, FaviconStore
  Importer/       Chromium and Arc parsers. Pure `ImportPlan` values, no UI
  Extensions/     ExtensionManager (one WKWebExtensionController per profile), CRX/zip install, catalog
  Views/
    Shell/        MainWindowView: sidebar + content card, ContentToolbar above the page or in the sidebar
    Toolbar/      AddressField, NavigationButtons, CopyLinkButton (shared by the top bar and the sidebar address bar)
    Sidebar/      SidebarView, SpaceSwipeContainer, FavoritesGrid, PinnedTree, TabList, SpaceSwitcher, SidebarRow
    Settings/     Settings scene: General (search engine, iCloud Sync), Appearance (address bar position, Dock icon), Extensions
    Import/       Import sheet (File → Import…) and the first-launch welcome sheet
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
`Space { id, name, symbol (SF Symbol name), emoji?, color: SpaceColor, profileID, sortKey, modifiedAt, deletedAt? }`. `emoji` is optional. Older `library.json` files omit it and still decode. The space switcher draws the emoji when it is set, and the SF Symbol otherwise.

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

- **favorites**: pinned sites shown as the favicon grid at the top of the sidebar. Sites only, no folders, flat. Rows are balanced for the sidebar width (at most four per row); tiles in a row share that row's width.
- **pinned**: pinned sites and (nested) folders below the grid.
- **tabs**: today's unpinned tabs. Sites only, flat. Every open unpinned tab *is* a `.tabs` item, which is how tabs survive relaunch.

A pinned or favorite site keeps `url` as its home. Navigating the live tab does not change that URL or the saved title. `PinnedPage` treats two URLs as the same page when only the fragment or a trailing slash differs. While the live page differs, a pinned row shows a secondary `/` between the icon and the current page title, and a favorite tile shows a small dot. Clicking the pin's icon loads the home URL (a new load, not a history walk). Clicking a favorite that is already selected does the same. Closing the tab unloads it and drops its interaction state, so the next open loads the home URL. The context menu item "Replace Pinned URL with Current", shown only while away, writes the live URL and title through `LibraryStore.updateItem` (one record, `modifiedAt` updated). The favicon is the host cache the live tab already filled; sidebar items have no icon field.

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
- The sync layer is in the tree and stays idle until iCloud Sync is turned on. See [Sync](#sync).
- Decision: **plain Codable + JSON file, not SwiftData.** The data set is small (hundreds of records), JSON is easy to inspect/import/export, and CKSyncEngine wants explicit control over records and change tracking, which SwiftData hides.

### Persistence
`~/Library/Application Support/myBrowser/` (`library.json`, `session.json`, `Favicons/`). Writes are debounced (~0.5 s) and atomic; also flushed on `applicationWillTerminate`. A `schemaVersion` field allows migrations. Tests use a temp directory.

## Import

Parsers in `Importer/` are `nonisolated`. They turn a Chromium `Bookmarks` file or Arc's `StorableSidebar.json` into an `ImportPlan` (profiles, spaces, and a tree of sites and folders per sidebar section). `LibraryStore.apply(_:to:)` in `LibraryStore+Import.swift` writes that plan in one batch, so the library saves once. Cookies are never copied.

Chromium-family browsers (Chrome, Brave, Edge, Vivaldi, Arc's `User Data`, Chromium): profile names come from `Local State` → `profile.info_cache`. The user adds the bookmarks to a new space named after the profile, or appends them to an existing space. The bookmarks bar is a pinned folder named "Bookmarks Bar", unless the user hoists its children to the pinned root. "Other Bookmarks" and "Mobile Bookmarks" are pinned folders. Empty folders and `javascript:` URLs are dropped. The same URL twice in one folder keeps the first copy.

Arc: `sidebar.containers[].spaces` and `items` are flat lists alternating an id string and an object. Items form a tree via `childrenIds`. `data.tab` is a site (`savedURL`), `data.list` is a folder, and `data.itemContainer` is `pinned`, `unpinned`, `topApps`, or `spaceItems` (a space column whose pinned/unpinned role is the matching `newContainerIDs` entry). Each Arc space keeps its name, emoji (or the closest SF Symbol), and nearest `SpaceColor` from `windowTheme.primaryColorPalette.midTone`. Spaces that shared an Arc profile share one new `Profile`. Pinned tabs and nested folders keep their order. Favorites (`topApps`, one list per Arc profile) are copied onto every imported space of that profile. Unpinned tabs stay out unless the user includes them; they are flattened into the tabs section.

File → Import… (⌘⇧I) lists what it found. The first launch, when `hasCompletedOnboarding` is unset and `library.json` did not exist, shows the same sheet with Start Fresh. An existing library sets the flag so people who already browse are not asked.

## Window / scene structure

- Phase 1: one main window (`Window` scene, id `main`) with one `BrowserModel`. `LibraryStore` and `SessionStore` are app-level singletons owned by the app and injected. Multiple windows (each its own `BrowserModel` sharing the library) come later.
- Settings (`Settings` scene, ⌘,): **General** — default search engine (`SearchEngine.defaultsKey`) and iCloud Sync (beta), disabled until `MBCloudKitContainer` is set. **Appearance** — address bar position (`AddressBarPosition.defaultsKey`: `top` default, or `sidebar`) and the Dock icon (`AppIconVariant.defaultsKey`: `light` default, or `dark`). **Extensions** — installed web extensions, per-profile enablement, install from a file or the Chrome Web Store. General and Appearance are `@AppStorage` over `UserDefaults`. Grouped `Form`.
- Window: hidden title bar, full-size content view, transparent title bar; the traffic lights sit over the sidebar like Arc. `WindowConfigurator` (an `NSViewRepresentable` that grabs `view.window`) applies the AppKit tweaks and moves `standardWindowButton`s so their vertical centre matches the toolbar. It re-applies that position on resize and when leaving fullscreen (AppKit resets the buttons). While fullscreen is active the system owns the buttons.
- Layout (`MainWindowView`): full-height sidebar on the left (behind-window vibrancy), web content on the right as a rounded card inset by a few points. The sidebar toggles with ⌘S (View menu "Hide Sidebar" / "Show Sidebar", plus a `sidebar.left` button). When hidden, the card fills the window edge to edge: no inset, no shadow, so the sidebar material does not leave a frame. Collapse and the address-bar setting share one spring (`SidebarMotion.sidebar`). The traffic-light centre stays on `SidebarMetrics.chromeCenterFromTop` in both modes, so the lights do not jump.
- Toolbar (`ContentToolbar`): `NavigationButtons` (back, forward, reload/stop) and `AddressField` (with `CopyLinkButton`) read `BrowserModel` from the environment and take an optional `ToolbarChrome`. Extension action buttons sit at the trailing end of the content toolbar, and on their own row under the address field when that field is in the sidebar. Up to four icons show; the rest are in a puzzle-piece menu. The resting field shows `URLDisplay`: host without scheme or `www.`, then at most the last two word-like path segments (short, numeric, locale, version, and id segments omitted), no query or fragment. Clicking it (or Cmd+L) opens the command bar in edit-current mode with the full URL selected. ⌘R is handled only by `KeyMonitor` (Ctrl+R does nothing; key repeat does not reload again). ⌘⇧C copies the current URL. While a page loads, the reload arrow (`arrow.clockwise`) spins continuously and eases to upright when loading ends; clicking it during a load stops the page. A thin progress line still runs under the bar.
  - **Top** (default): the bar sits across the top of the content card. A usable page colour crossfades (~0.25s) in as a low-saturation wash held close to the window background. A transparent or neon colour keeps the window background. The URL is plain secondary-weight text beside back/forward, with no field and no site colour behind it. Hover, focus, and editing show a neutral, low-contrast rounded field. The sidebar's top row is only the traffic lights and the sidebar-toggle button. When the sidebar is hidden, the toolbar keeps ~74pt of leading space so the controls clear the traffic lights, and a matching top spacer keeps that row on the same line as when the card was inset.
  - **Sidebar**: the same controls sit on the traffic-light row (navigation to the right of the lights, address field below). The field is a pill. Their chrome stays untinted, because the page colour is not painted on the sidebar. The content card has no toolbar and keeps its normal inset. When the sidebar is hidden, the content toolbar is shown anyway (plain text, no pill) so the URL stays visible.
- Sidebar rows use a flat highlight (soft white in light mode, white at about 12% in dark mode) with the system label color, so the title stays readable. They do not use `glassEffect`. Space icons share one size; the selected space is a small rounded chip tinted with the space color at about 16–18%, and the symbol is drawn in the space color.
- Folder disclosure uses `SidebarMotion.disclosure` (0.2s, no bounce). There is no chevron: a closed folder draws `folder` and an expanded one draws `folder.fill` (no open-folder SF Symbol), magic-replacing on that spring inside a fixed 16×16 frame. The clipped children and the rows below share the spring, and folder icons sit on the same leading edge as site favicons. Each parent’s children are a `SidebarSiblingList`. Toggling one folder publishes only that list, so favorites, tabs, and other folders do not rebuild. The open state is still `SidebarItem.isExpanded`, saved with the debounced library write.
- The app's own animation follows the display, not a 60Hz timer. Space swipe (`SpaceSwipeMotion`), folder disclosure, and the sidebar divider (`SidebarResizeHandle`) are SwiftUI springs and a drag gesture. The reload arrow's `TimelineView` has no minimum interval. The back/forward swipe sampler uses the view's display link on the common run-loop modes, so it keeps firing inside WebKit's tracking loop.
- Command bar: a SwiftUI overlay centred over the window (glass panel), not a separate NSPanel. It opens with a short spring (~0.18s) and closes faster.

## WebKit management

- `ProfileManager` caches one `WKWebsiteDataStore(forIdentifier: profile.id)` per profile and builds a `WKWebViewConfiguration` per tab from it (shared data store ⇒ shared cookies within a Space). The same configuration receives that profile's `WKWebExtensionController`.
- Page rendering follows the display. WebKit's `PreferPageRenderingUpdatesNear60FPSEnabled` (Safari → Develop → Feature Flags → "Prefer Page Rendering Updates near 60fps") defaults on and holds `requestAnimationFrame`, CSS animations, and page rendering updates near 60fps on a ProMotion or high-refresh display. macOS 26 has no public switch. `PageRenderingRate` turns that feature off before the web view is created, on every profile configuration, on `window.open` configurations, and on each extension controller's web view configuration, via `WKPreferences` `_features` / `_setEnabled:forFeature:` (the same private list Safari uses; same kind of call as Picture in Picture). Threaded scrolling, async frame scrolling, and async overflow scrolling already default on and are left on. With the flag off, a page updates at the display's rate; left on, the same page stays near 60fps.
- `WebContentView` is an `NSViewRepresentable` around a plain container `NSView`; when the selected tab changes it removes the old `WKWebView` and adds the new one as a subview (pinned to edges). Web views are never recreated on selection changes, so page state is kept.
- Space switching swaps the sidebar contents and selects that space's last selected item; live tabs of other spaces stay loaded (memory pressure handling / tab unloading is Phase 2+).
- `target=_blank` / `window.open` / Cmd-click: `WKUIDelegate.createWebView` → new `.tabs` item in the same space (Phase 1 opens in a new tab and selects it; Cmd-click opens in background).
- Back/forward: `allowsBackForwardNavigationGestures = true` (Safari-style two-finger swipe on the page). Decision: **page swipe = back/forward; swipes on the sidebar switch spaces**. `SpaceSwipeContainer` claims a horizontal trackpad swipe on the space column only (`SpaceSwipeTracker`); vertical list scrolling and the web view are left alone. Crossing the space-swipe commit line (30% of the column, or a flick that will commit) ticks the trackpad once. Crossing WebKit's history-swipe completion distance (`min(187.5pt, half the page)`) ticks once. Both go through `Haptics` and do not repeat while the finger stays past the line.
- Favicons: `FaviconStore` downloads `/favicon.ico` or the page's `<link rel=icon>` (via JS after load) and caches PNGs per host in `Favicons/`. Not synced.
- Picture in Picture uses the system panel (the separate "Picture in Picture" window), not a window this app draws. macOS `WKWebViewConfiguration` has no public `allowsPictureInPictureMediaPlayback` (iOS only) and the private preference defaults to off, so each configuration turns `_setAllowsPictureInPictureMediaPlayback` on. `_togglePictureInPicture` is a no-op without a Touch Bar, so enter and exit call `HTMLVideoElement.webkitSetPresentationMode` (`picture-in-picture` / `inline`), falling back to `requestPictureInPicture`. That call has to carry a user-gesture bit or WebKit changes the presentation mode and never opens the panel; public `evaluateJavaScript` does not set the bit, so the app uses WebKit's `withUserGesture` script entry point. A page script (all frames, including shadow roots) reports a playing video only when it is at least 160×90 and does not set `disablePictureInPicture` — otherwise there is no toolbar button. `pip.enter` sits in the address row while that is true (⌘⇧P, View menu, sidebar site menu). Automatic Picture in Picture is on by default (Settings → General, `autoPictureInPicture`): leaving the tab or the window moves a playing video into the panel, and selecting that tab again, or focusing the window after a focus-triggered PiP, returns it inline. The panel's return control ends PiP and selects that tab and its space. The web view stays attached behind the current page for the whole session, because detaching it closes the panel.

## Web extensions

- `ExtensionManager` is app-level. It keeps one `WKWebExtensionController` per profile, created with `WKWebExtensionController.Configuration(identifier: profile.id)`, so an extension's storage stays with that profile. Enabling an extension in one profile leaves other profiles' spaces alone.
- Installed packages are unpacked under `~/Library/Application Support/myBrowser/Extensions/<extension-id>/`. `extensions.json` in that folder records id, name, version, source, the profile ids where it is enabled, and the granted and denied permissions and match patterns.
- Install sources: an unpacked folder, `.zip`, Firefox `.xpi`, Chrome `.crx` (CRX2 and CRX3; the header is stripped and the ZIP is unpacked with `/usr/bin/ditto`), and a Chrome Web Store URL or id. A store download whose signed id is not the id that was requested is rejected. Manifest V2 and V3 are accepted. The catalog loads at launch; only extensions enabled for a profile are loaded into that profile's controller.
- `BrowserTab` adopts `WKWebExtensionTab` (`Browser/BrowserTab+Extension.swift`). The main window is one `WKWebExtensionWindow`. Open, activate, close, and property changes are forwarded to the controller. An extension that opens a tab goes through `BrowserModel.openTabForExtension`, which returns the live tab. Extension pages (options, extension URLs) use that extension context's `webViewConfiguration`.
- A click calls `performAction(for:)`. When the action presents a popup, the controller delegate shows `action.popupPopover` anchored to the toolbar button. Permission requests are an Allow / Don't Allow sheet. The choice is written into `extensions.json` and applied with `setPermissionStatus` before the context loads.
- Enabling an extension that injects scripts reloads that profile's open http(s) pages so the scripts run. Launching the app loads the extension without reloading pages that are already open.
- A package that requests `privacy` or `webRequestBlocking` gets `ExtensionWebKitCompat` at install. WebKit has neither API, and it ignores `{cancel:true}` from `webRequest`, so the shim only fills the missing objects (`privacy`, a few `webNavigation` / `runtime` events, `alarms.create`, illegal menu patterns) and leaves the real `browser` object in place. uBlock Origin's cosmetic filters then run. Scriptlets use the same `tabs.executeScript` path. Network blocking does not. See `docs/ubo-network-blocking.md`.

## Command bar

- Cmd+T: new tab mode (empty field). Cmd+L: edit current URL (prefilled, selected); Enter navigates the current tab.
- Results: "Open URL" when input looks like a URL, "Search <engine>" otherwise, plus matching open tabs / pinned sites in the current space (title or URL contains the query) → switch to them.
- `URLInput.resolve(_:)` decides URL vs search. An explicit scheme is kept. `localhost`, IP addresses, a single label with `/` or a port (`photos/`, `coolify:8000`), `*.ts.net`, `*.local`, `*.internal`, `*.lan`, `*.home.arpa`, and any host with a port are `http`. A bare single label is `http` when it resolves and a search otherwise. Other `host.tld` values are HTTPS-first: one connection, certificate, or timeout failure falls back to `http` with the address-field "Not secure" mark, and never a confirm page. Relaxed hosts are not marked insecure. WebKit's known-host upgrade and user-mediated HTTPS fallback stay off.
- Default search engine: **Google** (enum `SearchEngine`: google, duckDuckGo, kagi, bing, ecosia). The choice is Settings → General, stored in `UserDefaults` under `SearchEngine.defaultsKey`.

## Keyboard shortcuts (Phase 1)

| Shortcut | Action |
|---|---|
| Cmd+T | Command bar, new tab |
| Cmd+L | Command bar, edit current URL |
| Cmd+W | Close tab (pinned/favorite: unload and reset to the saved URL; tabs: delete) |
| Cmd+Shift+T | Reopen last closed tab |
| Cmd+1…8 | Select n-th item in sidebar order (favorites, pinned (expanded), tabs); Cmd+9 = last |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous item in sidebar order |
| Cmd+Opt+→ / ← | Next / previous space |
| Cmd+[ / Cmd+] | Back / forward |
| Cmd+R | Reload (`KeyMonitor` only; Ctrl+R does nothing) |
| Cmd+Shift+C | Copy link |
| Cmd+S | Hide / show sidebar |
| Cmd+Shift+I | Import bookmarks or an Arc sidebar |
| Cmd+D | Pin / unpin current tab |
| Cmd+Shift+P | Enter or exit Picture in Picture |
| Esc | Close command bar / stop loading |
| Delete | Delete the focused folder. A non-empty folder asks first. Ignored while a field, the page, or the command bar is focused. |

## Sidebar drag and drop

The sidebar is a `VStack`/`ForEach`, not a `List`. Rows use `.draggable` and one `DropDelegate` (`onDrop`) so a drop can cross sections and nest. `LibraryStore.moveItem` stays same-space. Cross-space and nested drops go through `LibraryStore.move(_:toSpace:section:parentID:position:)` in `LibraryStore+Move.swift`.

- `move` takes a folder's live descendants with it in one batch: one `onChange`, one save. Descendants keep their parent links. Their `spaceID` and `section` change with the folder. `canDrop` rejects a folder dropped into itself or a descendant, and rejects folders in favorites or tabs (those sections are sites only, at the root).
- Dropping on a folder row inserts at the end of that folder. The folder expands after the pointer hovers there for about 0.6 s. Dropping between rows inserts before or after; the pointer's indentation picks the depth. An accent line (2 pt, rounded) marks the slot, inset to that depth. The dragged row fades. Its close button keeps its space and hides, so the title does not jump. Other rows reflow with `SidebarMotion.row`. Folder rows are plain buttons, like site rows: a tap gesture on the row would take the mouse-down and the folder would never start a drag. The expand click is ignored when a drag session is active or has just ended.
- Favorites accept sites only. Dragging between the tabs list and pinned pins or unpins. A link dragged from a page or another app (http/https only) becomes a new site at that slot. WebKit provides that link as an `NSURL`; the plain-text URL is the fallback. The insertion line clears when the drop is accepted. A link load finishes after that, and later updates from the same drop session do not bring the line back. A new tab in the current space is selected.
- Dropping on a space icon moves the item and its subtree. Sites keep their section. Folders can only live in pinned, so they land there. The current space stays selected. A live tab that changes space is unloaded, because the destination profile has different cookies. An unpinned tab stores its page URL on the item. A pinned or favorite site keeps its home URL.
- A two-finger space swipe that is still tracking always settles: a new touch that begins outside the sidebar, the window resigning key, or the app resigning active. Under 30% of the column width it springs back to 0. Past that, or on a flick, it commits.
- Drag haptics, also via `Haptics`: a new drop slot, a cross between Tabs and Pinned, a folder that opens after the hover delay, a Space icon becoming the drop target, and the drop itself. Each fires once per change. Hovering a folder without it opening is silent. Patterns and timing live in `Views/Haptics.swift`.

## Sync

iCloud sync uses `CKSyncEngine` on the private database, custom zone `Library` (`CKRecordZone.ID(zoneName: "Library")`). It is off unless every gate below passes. Until then the app does not create a `CKContainer` or a `CKSyncEngine`.

`SyncController` (`AppDelegate` owns one) starts the engine only when all of these are true:

1. `UserDefaults` `iCloudSyncEnabled` is true. The default is false. Settings → General shows **iCloud Sync (beta)**.
2. Info.plist contains a non-empty `MBCloudKitContainer` (the container id, `iCloud.ch.marvinvr.mybrowser`). That key is absent until the container exists, and the toggle stays disabled with the caption "Requires iCloud container — coming soon".
3. `FileManager.default.ubiquityIdentityToken != nil` (an iCloud account is signed in).

The flag is checked first. A false flag returns before the account token is read.

### Records

| Model | Record type | Record name |
|---|---|---|
| `Profile` | `Profile` | `id.uuidString` |
| `Space` | `Space` | `id.uuidString` |
| `SidebarItem` | `SidebarItem` | `id.uuidString` |

`CKRecord.ID(recordName:zoneID:)` uses the zone above. `RecordMapper` is a pure value transform (no network). `CKRecord` values are strings, dates, and numbers.

- **Profile:** `name`, `modifiedAt`, `deletedAt?`
- **Space:** `name`, `symbol`, `emoji?`, `color` (raw value), `profileID`, `sortKey`, `modifiedAt`, `deletedAt?`
- **SidebarItem:** `spaceID`, `section`, `kind`, `parentID?`, `title`, `url?` (absolute string), `sortKey`, `isExpanded` (0/1), `createdAt`, `modifiedAt`, `deletedAt?`

`.tabs` items are not mapped and are not uploaded. A fetched `.tabs` record is ignored. A remote deletion whose local row is a tab is ignored.

Synced rows are profiles, spaces, favorites, and pinned items (including folder trees). Tabs, `session.json`, favicons, and extensions stay on this Mac.

### Local edits to the engine

`LibraryStore.onChange` reports the ids a mutation touched. `SyncEngine` turns those into `CKSyncEngine.state.add(pendingRecordZoneChanges:)`. A live synced row is `.saveRecord`. A tombstone is `.deleteRecord`. Unknown ids (a hard-deleted tab) produce nothing. The first sync, when no engine serialization is stored yet, saves the `Library` zone and uploads every synced row. Fetched rows merge by id.

### Remote edits into the store

`LibraryStore.applyRemote(upserts:deletions:)` writes the tables directly and clears `onChange` for that call (the `applyingRemote` suppression), then schedules the normal debounced save. Remote `modifiedAt` / `deletedAt` are stored as received. An invalid `sortKey` is replaced with a fresh key after the last valid sibling; `SortKey.between` never traps (an invalid, equal, or out-of-order bound yields a key after the lower valid bound, or `a0` when neither bound is valid). A remote record deletion hard-deletes the local profile, space, or synced item. Tombstone fields on a record (`deletedAt`) stay as tombstones so last-writer-wins can still see them.

### Conflicts

Per record, last writer wins. The stamp is the later of `modifiedAt` and `deletedAt`.

- A strictly newer stamp wins, including a newer tombstone over an older edit and a newer edit over an older tombstone.
- Equal stamps: a tombstone beats a live edit. If both sides are live or both are tombstones, the server record wins so its system fields stay authoritative.
- `serverRecordChanged`: compare `modifiedAt` / `deletedAt`, keep the winner, and persist the server record's encoded system fields. A local win is uploaded again on a record built from those system fields (the change tag has to be the server's). A server win is applied with `applyRemote`.
- A save that fails with `unknownItem` because the server record is gone: if the local edit is newer than the `modificationDate` stored in the last system fields, the record is created again. Otherwise the local row is removed. A local tombstone is treated as already deleted and may be purged once it is old enough.
- Fetched record deletions have no timestamp. They hard-delete the local row.

### Tombstones

A local delete of a synced row sets `deletedAt` and pushes a record deletion. A remote record deletion hard-deletes the local row. `purgeAcknowledgedTombstones(sent:)` removes a tombstone only when its id is in the sent set and `deletedAt` is older than the cutoff (30 days). `SyncState.markDeletionSent` records that set in `sync-state.json` after the engine reports the delete (or `unknownItem` on a delete, which means the server already dropped it). The unguarded `purgeTombstones` is unchanged and is still not called on its own.

### sync-state.json

Same Application Support directory as `library.json`, via `JSONFileStorage` (schema 1).

- `engineState`: JSON-encoded `CKSyncEngine.State.Serialization` from each `stateUpdate` event. Passed back into the next `CKSyncEngine.Configuration`.
- `systemFields`: `[recordName: Data]` from `CKRecord.encodeSystemFields`.
- `acknowledgedDeletions`: record ids whose delete has been accepted.
- `awaitingAccountChoice`: an account switch is waiting for an answer.

### Account and zone

- **Sign out:** keep the library, reset sync state, drop the engine.
- **Switch account:** ask. "Sync" resets sync state, uploads this library, and merges fetched rows by id. "Turn Off" resets sync state and sets `iCloudSyncEnabled` to false. The library stays either way.
- **Zone deleted, purged, or encrypted-data reset** (`fetchedDatabaseChanges`), and **zoneNotFound / userDeletedZone** on a zone fetch: drop stored system fields (their change tags belonged to the old zone) and upload the library again.
- **Ordering:** `orderedSpaces` and `children` sort by `(sortKey, id.uuidString)`. Two devices inserting at the same spot keep both rows; the uuid string breaks the tie.

### Enabling the container

`myBrowser/myBrowser-iCloud.entitlements` is **not** referenced by `project.yml`. Debug and Release keep building and shipping without iCloud. When the container and a Developer ID provisioning profile exist, switch these on together:

1. Apple Developer: on the App ID `ch.marvinvr.mybrowser`, create the iCloud container `iCloud.ch.marvinvr.mybrowser` and enable CloudKit and Push Notifications. `CKSyncEngine` uses silent pushes, so the release entitlements include `com.apple.developer.aps-environment` = `production`.
2. Create a Developer ID provisioning profile for that App ID that includes the container, CloudKit, and Push. Download it.
3. `project.yml`, Release only: set `CODE_SIGN_ENTITLEMENTS` to `myBrowser/myBrowser-iCloud.entitlements`. That file replaces `myBrowser/myBrowser.entitlements` and already includes `com.apple.security.cs.allow-jit`. Leave Debug ad-hoc, with no iCloud entitlements.
4. `project.yml` `info.properties`: add `MBCloudKitContainer: iCloud.ch.marvinvr.mybrowser`. Without this key the toggle stays disabled and `SyncController` does not start.
5. `scripts/release.sh`: sign the app with `myBrowser/myBrowser-iCloud.entitlements` (the `sign_sparkle` `codesign` line). Embed the Developer ID profile at `Contents/embedded.provisionprofile`. The export fallback that treats "No profiles for" as success has to require this profile instead. Keep rejecting `get-task-allow`. Keep requiring `allow-jit`.

Do not flip those switches before the container and the profile exist. A Release build signed with the iCloud entitlements and no matching profile fails to launch.

## Decisions log
- 2026-10-22: JSON + Codable store instead of SwiftData (see Sync readiness).
- 2026-10-22: one Profile per Space by default; model allows sharing.
- 2026-10-22: not sandboxed.
- 2026-10-22: default search engine Google, chosen in Settings → General.
- 2026-10-22: page two-finger swipe = back/forward, sidebar swipe = spaces. Sidebar swipe commits past 30% of the column or on a flick, and rubber-bands on the first and last space.
- 2026-10-22: single window in Phase 1.
- 2026-10-22: address field and back/forward/reload live in a toolbar above the page by default. Settings → Appearance can move the same controls to the top of the sidebar. Tabs stay in the sidebar. Sidebar selection is a flat fill, not glass.
- 2026-10-22: the content toolbar tints from the page theme colour and shows a formatted URL. ⌘⇧C copies the link.
- 2026-10-23: the top address bar is plain secondary text. The pill exists only in the sidebar address-bar setting. The content toolbar's page tint is a low-saturation wash near the window colour, not the theme colour itself.
- 2026-10-23: the reload button spins its arrow while a page loads and eases to a stop when loading ends. Clicking it during a load stops the page. It does not swap to a stop icon.
- 2026-10-22: collapsed sidebar draws the content card edge to edge. Traffic lights stay vertically centred on the toolbar in both modes.
- 2026-10-22: bundle id `ch.marvinvr.mybrowser`; Sparkle feed on `main`; releases via `scripts/release.sh`.
- 2026-10-23: Dock icon is the light AppIcon unless Settings → Appearance picks dark. Applied at launch and on change with `NSApp.applicationIconImage` only. `NSWorkspace.setIcon` is not used; it modifies the signed bundle and breaks the code signature and Sparkle updates.
- 2026-10-23: CloudKit sync (`CKSyncEngine`, private zone `Library`) is in the app and off by default. It starts only when `iCloudSyncEnabled`, Info.plist `MBCloudKitContainer`, and an iCloud account are all present. The container and the iCloud entitlements file are not wired into the build yet.
- 2026-10-23: sidebar drag and drop uses `LibraryStore.move` (one batch, subtree included). A drop on a space icon keeps a site's section; folders land in pinned. A live tab that changes space is unloaded and keeps its URL. A space swipe that is still tracking settles on a new outside touch, resign-key, or resign-active.
- 2026-10-23: folder rows drag as plain buttons. A link drop reads `NSURL` from the pasteboard and falls back to the plain-text URL. The row close button hides for the duration of a drag without leaving the layout.
- 2026-10-23: Chrome-family bookmarks and Arc sidebars import through an `ImportPlan` applied in one `LibraryStore` batch. Arc favorites (`topApps`) are copied onto every imported space of that profile. `Space.emoji` is optional so older library files still open.
- 2026-10-23: web extensions use `WKWebExtensionController`, one controller per profile id. Packages are unpacked under `Application Support/myBrowser/Extensions`.
- 2026-10-23: uBlock Origin (MV2, Chromium zip) installs through Settings → Extensions. Cosmetic filters run. Scriptlets use `tabs.executeScript`. Blocking `webRequest` does not, and there is no content-rule bridge yet (`docs/ubo-network-blocking.md`).
- 2026-10-23: trackpad haptics use `NSHapticFeedbackManager` through `Haptics`. One pulse per state change: space-swipe detent, history-swipe threshold, drop slot, pin/unpin, folder auto-expand, space drop target, and the drop.
- 2026-10-23: folder disclosure is a 0.2s no-bounce spring. Sidebar views read per-parent `SidebarSiblingList`s, so one toggle does not refresh the rest of the column.
- 2026-10-23: the favorites grid balances rows (`ceil(n / maxPerRow)`, remainder on the earlier rows) so six icons are 3+3. Tiles in a row share its width. At most four per row, same as before.
- 2026-10-23: sidebar folders drop the disclosure chevron. Closed is `folder`, expanded is `folder.fill`, with a magic symbol replace in a fixed frame so rows stay aligned.
