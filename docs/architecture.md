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
  Browser/        BrowserModel (per-window coordinator), BrowserTab (one WKWebView), ProfileManager, FaviconStore, DownloadManager, PasskeyBroker
  Importer/       Chromium and Arc parsers. Pure `ImportPlan` values, no UI
  Extensions/     ExtensionManager (one WKWebExtensionController per profile), CRX/zip install, catalog, native messaging
  Views/
    Shell/        MainWindowView: sidebar + content card, ContentToolbar above the page or in the sidebar
    Toolbar/      AddressField, NavigationButtons, CopyLinkButton (shared by the top bar and the sidebar address bar)
    Sidebar/      SidebarView, SpaceSwipeContainer, FavoritesGrid, PinnedTree, TabList, SpaceSwitcher, SidebarRow
    Settings/     Settings scene: General (search engine, iCloud Sync), Appearance (address bar position, Dock icon), Extensions
    Import/       Import sheet (File → Import…) and the first-launch welcome sheet
    Web/          WebContentView (NSViewRepresentable that swaps the selected tab's WKWebView in)
    Downloads/    Toolbar downloads button, popover, and the downloads page
    CommandBar/   CommandBarView + CommandBarModel (results)
  Resources/      Assets.xcassets
myBrowserTests/   Swift Testing unit tests (model, SortKey, store, URL parsing)
```

## Data model

Two kinds of state:

1. **Library** (`LibraryStore`, `library.json`): profiles, spaces, sidebar items. This is the part that will sync via CloudKit in Phase 2 (except the `tabs` section, see below).
2. **Session** (`SessionStore`, `session.json`): local-only window state: selected space, selected item per space, focused pane per split, per-tab WebKit `interactionState` (back/forward history), recently closed tabs, last-active times, and archived tabs. Never synced. `focusedPaneBySplit`, `lastActiveAt`, and `archivedTabs` are optional on decode so an older session file still opens. UUID-keyed maps accept the encoder's alternating array and a JSON object with UUID keys. Schema stays 1.

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
  kind: .site | .folder | .split
  parentID: UUID?        // folder id within .pinned, or the split that owns this site. nil = section root
  title: String          // user title (folders, renamed pins) or last page title
  url: URL?              // .site: the pinned "home" URL; for .tabs items the current URL
  sortKey: String        // fractional index, ordering among siblings
  isExpanded: Bool       // folders
  splitFraction: Double? // this pane's share of its split. nil = equal with its siblings. omitted by older files
  splitAxis: SplitAxis?  // .split only: .horizontal | .vertical. nil = horizontal. omitted by older files
  createdAt, modifiedAt: Date
  deletedAt: Date?       // tombstone
}
```

- **favorites**: pinned sites shown as the favicon grid at the top of the sidebar. Sites only, no folders, no splits, flat. Rows are balanced for the sidebar width (at most four per row); tiles in a row share that row's width.
- **pinned**: pinned sites, (nested) folders, and splits below the grid. A split may sit inside a pinned folder.
- **tabs**: today's unpinned tabs. Root rows are sites and splits. Every open unpinned tab *is* a `.tabs` item (a split's members included), which is how tabs survive relaunch.

A pinned or favorite site keeps `url` as its home. Navigating the live tab does not change that URL or the saved title. `PinnedPage` treats two URLs as the same page when only the fragment or a trailing slash differs. While the live page differs, a pinned row shows a secondary `/` between the icon and the current page title, a pane in a pinned split does the same on its segment, and a favorite tile shows a small dot. Clicking the pin's icon loads the home URL (a new load, not a history walk). Clicking a favorite that is already selected does the same. Closing the tab unloads it and drops its interaction state, so the next open loads the home URL. The context menu item "Replace Pinned URL with Current", shown only while away, writes the live URL and title through `LibraryStore.updateItem` (one record, `modifiedAt` updated). The favicon is the host cache the live tab already filled; sidebar items have no icon field.

### Tabs (runtime)
`BrowserTab` (`@Observable`, main actor) is the live counterpart of a site item: `tab.id == item.id`. It owns at most one `WKWebView`, created lazily on first selection, so restored tabs cost nothing until used. It exposes `title`, `url`, `favicon`, `isLoading`, `estimatedProgress`, `canGoBack/Forward`, `themeColor`, and `goBack/goForward/reload/stop/load`. `themeColor` is the page tint: WebKit's `themeColor` when that colour is opaque, else `underPageBackgroundColor`, else a sample of the top of the page. On creation it restores `interactionState` from the session store if present (back/forward history survives relaunch).

`BrowserModel.tabs: [UUID: BrowserTab]` holds the live tabs. An item without a `BrowserTab` is "not loaded". Selecting it creates one.

### Split view

A split is one sidebar row that shows two to four pages side by side (or stacked) in the content area. `WebContentView` reads `BrowserModel.displayedContent` and lays every pane out in that order: side by side when the axis is horizontal, stacked when it is vertical. A 6pt gap separates the panes. Each pane clips to a continuous 8pt corner. One site still fills the card with no gap and no inner corner. Dragging a divider resizes the two panes beside it, live, without rebuilding web views. A pane will not go under about 240pt unless the card is too narrow for that. The drag writes `setFractions` when the pointer goes up. Double-clicking a divider clears the fractions back to equal. The focused pane has a thin accent outline; the others are slightly dimmed. A click in a pane, including inside the page, calls `focusPane`, so the toolbar, URL, back/forward, reload, and page tint follow that pane. Hovering a pane fades in a small glass pill at the top trailing corner: close, separate, and move along the axis. Dragging a sidebar site onto the leading or trailing edge, or onto the gap between panes, shows a half-pane preview. Dropping there calls `createSplit` anchored on the page already showing (the dragged page can still land on the leading side), or `addToSplit` when a split is already showing. A drop from another section is refused. At four panes the preview is not offered.

**Membership.** `kind: .split` is a container. Its panes are ordinary `.site` items with `parentID` set to the split's id, ordered by `sortKey` (left to right, or top to bottom when the axis is vertical). Members keep their own ids, history, and sync records. A split lives in `.pinned` or `.tabs`, never `.favorites`. Every member shares one section and the split's `spaceID`. `createSplit` and `addToSplit` return nil when a site is in another section, including a favorite or a tab paired with a pin. They do not rewrite that site's section. The anchor is `anchoredOn` when that id is in the group, otherwise the first id. The split takes the anchor's section, folder, and sort key. A content-card drop anchors on the page already showing. A pinned split may sit inside a folder (`split.parentID` is the folder id). There are no nested splits and no folders inside a split. `LibraryStore.move` / `moveItem` refuse a parent that is a split; `createSplit` and `addToSplit` are the only ways in. A site whose parent split or folder is not in the library yet is listed at the section root. Its stored `parentID` stays, and it nests again when that container arrives.

**Width and axis.** `splitFraction` on a member is that pane's share. `nil`, or any non-finite or non-positive value, means "equal". If any member's share is missing, every pane is equal (`SidebarItem.displayFractions`). `setFractions` writes one positive number per member, scaled so they sum to 1, or `[]` to clear them. Adding, removing, or separating a member clears every share. Swapping panes swaps sort keys only, so a wide pane stays wide. `splitAxis` is `.horizontal` (side by side) or `.vertical` (stacked). `nil` means horizontal. `createSplit` stores `nil` for horizontal so older-shaped rows stay small; `setSplitAxis` stores the value it is given, including `.horizontal`. The split row's menu and the View menu toggle "Stack Vertically" and "Side by Side". Neither has a shortcut. Both fields are optional and omitted when nil, so a `library.json` from before split view still decodes (`schemaVersion` stays 1). On a CloudKit record the same keys are always assigned, including nil, so clearing a share or an axis removes the old value from a reused record.

**Invariants.** A live split has 2...4 live site members (`SidebarItem.minimumSplitMembers` / `maximumSplitMembers`). Dropping to one dissolves it: that site takes the split's `spaceID`, section, `parentID`, and `sortKey`, and its fraction is cleared. Dropping to zero removes the empty split. A pinned split is tombstoned (synced delete). A `.tabs` split is hard-deleted like other `.tabs` items. Deleting the split itself deletes its members the same way a folder deletes its subtree (pinned: tombstone the subtree; tabs: hard-delete it). `separate` releases one pane and places it immediately after the split; dissolve then releases the survivor into the split's slot. `applyRemote` reconciles a split that already existed when a member is deleted or tombstoned. It does not dissolve a container that arrived in that same batch with only some of its members. The content area shows the panes that have arrived, including a single pane, instead of the empty state. Closing a pane with no saved URL deletes it when the live tab also has no URL, so a blank pane opened into a pinned split does not remain as an empty pin. When that pane has loaded a page, Close stores the live URL and title as the pin's home and unloads it. That close does not add a recently-closed entry, the same as closing any other pin. Unpinning a synced item into `.tabs` still does not emit a CloudKit delete; splits follow that existing rule.

**Selection and focus.** The sidebar selection is the split id (`selectedItemBySpace`). The focused pane is `SessionStore.focusedPaneBySplit`, local only, so it is not a synced field. `selectedTab` (toolbar, URL, back/forward, shortcuts, extensions) is that focused member. Selecting a member directly (command bar, Ctrl-Tab, Cmd+1…9) selects its split and focuses that member. `displayedContent(for:)` answers what the content area shows for an item or the current selection: one pane for a site, or the ordered panes, fractions, axis, and focused id for a split or any of its members. It creates unloaded `BrowserTab`s and does not load web views. The first time a split is shown, including a relaunch that already had it selected, every pane loads. A later focus change loads the focused pane and leaves an unloaded sibling unloaded. Selecting the split again after leaving it loads panes that are not already loaded, including a pinned pane that was closed. Closing the window and relaunching restores the split and its members; members stay lazy until the split is shown.

**What walks which list.** The sidebar draws one row per split. That row is the same height as a site row and shows every pane: favicon, title, a hairline between panes, titles truncated to equal widths, and the focused pane's title in a slightly heavier weight. Selection and hover use the same chip as other rows. Clicking a pane selects the split and focuses that pane. The row's drag moves the whole group. The sidebar X and Cmd+W close the focused pane, not the whole group. Delete on a pinned split removes the group. A site row's menu can open a split with the selected tab, with a recent tab, or with a new empty tab, and can add the site to the selected split while it has fewer than four panes. A split row's menu can separate or close each pane, swap two panes, switch between Side by Side and Stack Vertically, or separate all. Separate, Swap, and Focus Next / Previous stay disabled unless the selection can run them (`canSeparatePane` for separate and focus, `canSwapPanes` for swap). Keyboard order, Cmd+1…9, and the extension tab list replace each split with its member sites and do not also list the container, so Cmd+1…9 counts panes. The command bar searches `kind == .site`, so members appear once and the split does not. Typing "split", "separate", "swap", or "focus next" also offers the matching split command when the selection can run it. The importer does not create splits.

Call these through `BrowserModel` so selection and focus stay consistent. The store methods are the same operations without the window state.

`LibraryStore`:

- `splitMembers(of:) -> [SidebarItem]`
- `splitContainer(of:) -> SidebarItem?`
- `createSplit(tabIDs:axis:anchoredOn:) -> SidebarItem?`
- `addToSplit(tabID:splitID:at:) -> SidebarItem?`
- `separate(tabID:) -> SidebarItem?`
- `movePane(tabID:to:)`
- `swapPanes(splitID:_:_:)`
- `setFractions(splitID:_:)`
- `setSplitAxis(splitID:axis:)`
- `reconcileSplit(_:)`
- `clearSplitFractions(_:)`

`BrowserModel` (the content area and later UI):

- `createSplit(tabIDs:axis:anchoredOn:) -> SidebarItem?` — selects the new split. The anchor is `anchoredOn` when that id joined, otherwise the first pane's place. Focus is the previously selected member when it joined, otherwise the first pane.
- `addToSplit(tabID:splitID:at:) -> SidebarItem?` — if that tab was selected, the split becomes selected and that pane is focused. If the split was already selected, the new pane loads.
- `separate(tabID:) -> SidebarItem?` and `removeFromSplit(tabID:)` — the pane becomes the next item after the split. A focused pane that was pulled out becomes the selection. A dissolved split leaves the survivor selected when the split was selected.
- `movePane(tabID:to:)` — `to` is the index in the final order.
- `swapPanes(splitID:_:_:)`
- `setFractions(splitID:_:)` — `[]` clears.
- `setSplitAxis(splitID:_:)`
- `focusPane(tabID:)` — selects the member's split and focuses that pane.
- `displayedContent(for:) -> DisplayedContent?` — nil uses the selection. `DisplayedContent` is `itemID`, `isSplit`, `axis`, `panes: [DisplayedPane]`, `focusedID`. `DisplayedPane` is `id`, `fraction`, `tab`.
- `navigableAnchor(for:)` — the focused pane when the selection is a split.
- `resolvedFocus(in:)` — stored focus when that site is still a member, otherwise the first pane.

### Tab archive

Unpinned tabs (the `.tabs` section only) that have not been selected for longer than Settings → General → **Archive tabs after** are closed into an archive. The choices are 12 hours, 24 hours (the default), 7 days, 30 days, and Never (`UserDefaults` key `archiveTabsAfter`). An info button on that row explains the rule. A tab is kept when it is the selected item of its space, playing audio or video (`WKWebView` media state, or a large playing video), in Picture in Picture, or has an active download. Pinned sites, favorites, and items inside pinned folders are not candidates.

`SessionStore.lastActiveAt` maps an item id to the last time it was selected. It is session state, not a field on `SidebarItem`, so opening a pin does not rewrite a record that syncs. Selecting a tab stamps it and stamps the tab that was just left, so the time it stayed selected counts as viewed. A tab with no stamp is stamped with the check time on the first sweep, so turning the feature on does not archive the whole list. The sweep runs about every three minutes, and again at launch and when the app becomes active. The clock is injectable; idle time has to be longer than the interval.

`SessionStore.ArchivedTab` keeps the item snapshot (same id), the WebKit interaction state, `archivedAt`, and `lastActiveAt`. Entries older than 30 days are dropped, and so are entries whose space is gone. History → Archived Tabs… and a command bar match for "archive" open a search list. Reopening restores the `.tabs` item at the top of its space with its history. The same close is pushed onto the closed-tab stack, so ⌘⇧T reopens the most recent one and removes it from the archive. The archive is local, like `.tabs`: it is not uploaded. A pane whose split is the selected row counts as selected, and selecting a split stamps its unpinned panes, so an open split is not archived.

### Ordering keys
`sortKey` is a fractional index string (`SortKey.between(a, b)`, base-62 digits, lexicographic compare). Inserting/moving only rewrites the moved record, which keeps CloudKit conflicts local to one record. Ties (two devices inserting at the same spot) are broken by `id`.

### Tombstones
Deleting a Profile/Space/favorites/pinned item sets `deletedAt` (and `modifiedAt`) instead of removing the record; everything reading the store filters tombstones. Deleting a folder tombstones its descendants. Deleting a pinned split tombstones its members. Tombstones are purged after 30 days (Phase 2: only once CloudKit has acknowledged the deletion). `.tabs` items, including a tabs split and its members, are local-only and hard-deleted.

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
- Settings (`Settings` scene, ⌘,): **General** — default search engine (`SearchEngine.defaultsKey`), **Archive tabs after** (`archiveTabsAfter`: `12h`, `24h` default, `7d`, `30d`, `never`) with an info tooltip, and iCloud Sync (beta), disabled until `MBCloudKitContainer` is set. **Appearance** — address bar position (`AddressBarPosition.defaultsKey`: `top` default, or `sidebar`) and the Dock icon (`AppIconVariant.defaultsKey`: `light` default, or `dark`). **Extensions** — installed web extensions, per-profile enablement, install from a file or the Chrome Web Store. General and Appearance are `@AppStorage` over `UserDefaults`. Grouped `Form`.
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
- `WebContentView` hosts every pane of `displayedContent` in one AppKit canvas. The canvas sets each pane's frame, and the web view fills that frame. Web views are never recreated when the selection, the focused pane, or a divider changes. An unloaded pinned pane stays a blank placeholder until it is focused. A single site fills the card. A Picture in Picture web view stays attached to the window when its pane is not showing, because detaching it closes the system panel. Parking adds that web view onto the park host and lets AppKit reparent it. A pane does not set the web view's frame while that view's window is not the pane's window, so a fullscreen video is not pulled back during a divider drag.
- Space switching swaps the sidebar contents and selects that space's last selected item; live tabs of other spaces stay loaded (memory pressure handling / tab unloading is Phase 2+).
- `target=_blank` / `window.open` / Cmd-click: `WKUIDelegate.createWebView` → new `.tabs` item in the same space (Phase 1 opens in a new tab and selects it; Cmd-click opens in background).
- Back/forward: `allowsBackForwardNavigationGestures = true` (Safari-style two-finger swipe on the page). Decision: **page swipe = back/forward; swipes on the sidebar switch spaces**. `SpaceSwipeContainer` claims a horizontal trackpad swipe on the space column only (`SpaceSwipeTracker`); vertical list scrolling and the web view are left alone. Crossing the space-swipe commit line (30% of the column, or a flick that will commit) ticks the trackpad once. Crossing WebKit's history-swipe completion distance (`min(187.5pt, half the page)`) ticks once. Both go through `Haptics` and do not repeat while the finger stays past the line.
- Favicons: `FaviconStore` downloads `/favicon.ico` or the page's `<link rel=icon>` (via JS after load) and caches PNGs per host in `Favicons/`. Not synced.
- File URLs load with `loadFileURL(_:allowingReadAccessTo:)` so a downloaded PDF or image can open in a tab.

## Downloads

`DownloadManager` (one per window model, file `downloads.json` next to `library.json`) records every `WKDownload`. The list is per profile: the popover and the downloads page show the current space's profile. History stays on this Mac and is not synced.

WebKit is asked to download when:

- the navigation action has `shouldPerformDownload` (the `download` attribute),
- the main-frame response is `Content-Disposition: attachment`,
- the main frame's MIME type cannot be shown (a zip, a disk image),
- the context menu creates a download (Download Linked File, Save Image, Download Media). That path is `_webView:contextMenuDidCreateDownload:`.

The file is written to `~/Downloads` as `name.pdf.download`, then renamed to `name.pdf`. A name that is already there becomes `name (1).pdf`. Pause cancels the `WKDownload` and keeps `resumeData`. Resume and retry use a web view on the same profile's data store, so cookies stay with that profile. Closing the tab parks the web view offscreen until its downloads finish. A launch turns an in-progress row into paused when resume data was saved, otherwise failed, and the row stays in the list.

On finish the file gets `com.apple.quarantine` (`0083;<hex time>;myBrowser;<uuid>`) and `com.apple.metadata:kMDItemWhereFroms` (the file URL, then the page). The Downloads stack in the Dock is bounced with `com.apple.DownloadFileFinished`.

The toolbar button (`arrow.down.circle`) sits at the trailing end of the address bar. It appears while a download is active, and for five minutes after one finishes, or until Clear. A ring in the toolbar symbol colour tracks bytes. The popover lists icon, name, size, progress, and speed, with pause, resume, cancel, retry, show in Finder, open, and open in the default app. A finished PDF, image, text, video, or audio file opens in a new tab (`file://` with read access to that file). Other types open in the default app. Cmd+Shift+J opens the downloads page for the current profile, with search.
- Picture in Picture uses the system panel (the separate "Picture in Picture" window), not a window this app draws. macOS `WKWebViewConfiguration` has no public `allowsPictureInPictureMediaPlayback` (iOS only) and the private preference defaults to off, so each configuration turns `_setAllowsPictureInPictureMediaPlayback` on. `_togglePictureInPicture` is a no-op without a Touch Bar, so enter and exit call `HTMLVideoElement.webkitSetPresentationMode` (`picture-in-picture` / `inline`), falling back to `requestPictureInPicture`. That call has to carry a user-gesture bit or WebKit changes the presentation mode and never opens the panel; public `evaluateJavaScript` does not set the bit, so the app uses WebKit's `withUserGesture` script entry point. A page script (all frames, including shadow roots) reports a playing video only when it is at least 160×90 and does not set `disablePictureInPicture` — otherwise there is no toolbar button. `pip.enter` sits in the address row while that is true (⌘⇧P, View menu, sidebar site menu). Automatic Picture in Picture is on by default (Settings → General, `autoPictureInPicture`): leaving the tab or the window moves a playing video into the panel, and selecting that tab again, or focusing the window after a focus-triggered PiP, returns it inline. The panel's return control ends PiP and selects that tab and its space. The toolbar button and ⌘⇧P act on the focused pane (`selectedTab`), so a selected split does not send the container id. Selecting a split moves the previous tab into Picture in Picture only when that tab is no longer on screen. Moving focus between panes that stay visible keeps both inline and records the focused pane as the one a later leave will park. The web view stays attached behind the current page for the whole session, because detaching it closes the panel.

## Web extensions

- `ExtensionManager` is app-level. It keeps one `WKWebExtensionController` per profile, created with `WKWebExtensionController.Configuration(identifier: profile.id)`, so an extension's storage stays with that profile. Enabling an extension in one profile leaves other profiles' spaces alone.
- Installed packages are unpacked under `~/Library/Application Support/myBrowser/Extensions/<extension-id>/`. `extensions.json` in that folder records id, name, version, source, the profile ids where it is enabled, and the granted and denied permissions and match patterns.
- Install sources: an unpacked folder, `.zip`, Firefox `.xpi`, Chrome `.crx` (CRX2 and CRX3; the header is stripped and the ZIP is unpacked with `/usr/bin/ditto`), and a Chrome Web Store URL or id. A store download whose signed id is not the id that was requested is rejected. Manifest V2 and V3 are accepted. The catalog loads at launch; only extensions enabled for a profile are loaded into that profile's controller.
- `BrowserTab` adopts `WKWebExtensionTab` (`Browser/BrowserTab+Extension.swift`). The main window is one `WKWebExtensionWindow`. Open, activate, close, and property changes are forwarded to the controller. An extension that opens a tab goes through `BrowserModel.openTabForExtension`, which returns the live tab. Extension pages (options, extension URLs) use that extension context's `webViewConfiguration`.
- A click calls `performAction(for:)`. When the action presents a popup, the controller delegate shows `action.popupPopover` anchored to the toolbar button. The popover is resized to the popup document after it lays out (capped around 480×680). Permission requests are an Allow / Don't Allow sheet. The choice is written into `extensions.json` and applied with `setPermissionStatus` before the context loads.
- The web view is created, `didOpenTab` runs, and only then does the first navigation start. Content scripts, including `all_frames`, are registered before `document_start`. Enabling an extension that injects scripts reloads that profile's open http(s) pages. Launching the app loads the extension without reloading pages that are already open.
- A package that requests `privacy` or `webRequestBlocking` gets `ExtensionWebKitCompat` at install. WebKit has neither API, and it ignores `{cancel:true}` from `webRequest`, so the shim only fills the missing objects (`privacy`, a few `webNavigation` / `runtime` events, `alarms.create`, illegal menu patterns) and leaves the real `browser` object in place. uBlock Origin's cosmetic filters then run. Scriptlets use the same `tabs.executeScript` path. Network blocking does not. See `docs/ubo-network-blocking.md`.
- Chrome Web Store ids (32 characters, `a`–`p`) are `browser.runtime.id`. The context base URL stays `webkit-extension://<id>/`. Setting it to `chrome-extension://` makes `WKWebExtensionController.load` hang, rather than throw, so there is no fallback (seen with 1Password on macOS 27). Native hosts are still started with `chrome-extension://<id>/` as their origin argument.
- Extension commands are delivered from the key-down monitor via `WKWebExtensionContext.performCommand(for:)`, for the selected space's profile only, and they are not repeated. The event reaches the page when no manifest command matches, so a content script can still see ⌘\\. Browser shortcuts (⌘T, ⌘W, ⌘R, and the rest of the table below) win when both match.
- `runtime.connectNative` / `runtime.sendNativeMessage` are bridged to a Chromium stdio host (`NativeMessaging.swift`). The host manifest is the first `NativeMessagingHosts/<name>.json` under this app, Chrome, Edge, Brave, Arc, Vivaldi, Chromium, or Firefox that lists the extension's origin. Frames are a native-endian length plus JSON. The host is spawned as a child of myBrowser with one argument, the origin (`chrome-extension://<id>/` for a Chrome id). Message bodies are not logged. For `com.1password.1password`, if no manifest is installed, the bridge uses 1Password's Browser Helper at its standard path when that binary is executable and the origin is one of the ids 1Password publishes. WebKit returns the `connectNative` port before the native side exists. A `postMessage` in that same turn is queued, and when the port connects WebKit sends the queue back to the extension instead of to the host. The service-worker prelude holds that first `postMessage` for 50ms so the host receives it (`NmAuthorizePartnerBrowser` for 1Password).
- On this OS, release WebKit hides `chrome.notifications` unless the extension controller is in testing mode (`_setTestingMode:`, set with KVC when the selector exists). The stub that then appears is incomplete: `onClicked` exists, `onClosed`, `create`, `clear`, `update`, and `getAll` do not. `chrome.notifications` is main-world only, so a content script still sees it as missing. There is no `WebExtensionNotificationsEnabled` preference on this WebKit. `webNavigation` is missing `onCreatedNavigationTarget` (and the history, fragment, and tab-replaced events). `storage.managed` is missing. A property added once while the service worker evaluates is gone before 1Password's async init reads it, so a short prelude is prepended to an MV3 service worker that asks for `notifications` or `webNavigation`, and the same script is injected into extension pages. The prelude fills only the missing members and repeats that fill for about twelve seconds. It does not post real notifications. Static `import` in the worker is unchanged. Dynamic `import()` is not available in service workers here. A user script does not run in the service worker.

### 1Password

The Chrome Web Store extension id is `aeblfdkhhhdcdjpifhhbdiojplfjncoa`. Install it from Settings → Extensions. Allow native messaging, notifications, and site access. The inline menu is the extension's content script (all frames, `document_start`); that script listens for ⌘\\. The manifest commands are ⌘⇧X (`_execute_action`, the popup) and ⌘⇧L (lock). The toolbar reads the manifest icon. It does not read `WKWebExtension.Action` while building the SwiftUI toolbar, because that walk drops the toolbar update for this extension.

1Password shows its toolbar popup only after the desktop app is connected, or when an account is already stored in the extension. Until then it sets the popup to empty and a toolbar click opens `/app/app.html#/page/welcome` as a tab. That extension URL is loaded in a web view that uses the extension's configuration. A `windows.create({type:"popup"})` of an extension page (the detached popup, about 600×472) is a separate panel, not a sidebar tab.

Unlocking with the 1Password desktop app is native messaging to `com.1password.1password` (`1Password-BrowserSupport`). The helper checks the parent process code signature (`browser_verification/apple.rs`). It accepts known browsers, and other browsers only after **Settings → Browser → Add Browser**. The added app has to be code-signed by Apple, with the hardened runtime, and chosen from the Applications folder. An ad-hoc Debug build starts the helper and the extension reports `PortClosed` (the helper exits; no `BrowserSupport` child stays up). A Developer ID build of myBrowser in `/Applications` is what Marvin adds. In the extension, "Integrate this extension with the 1Password desktop app" stays on. Restart the browser after adding it. Inline fill, save-login, and the unlocked popup need that connection. They do not work on an ad-hoc debug build.

1Password as a **passkey / password provider** is separate: System Settings → General → AutoFill & Passwords. Settings → General → AutoFill Providers… opens that pane. The extension fills from the desktop app. The system passkey sheet fills from the provider. They are not the same connection.

## Passkeys

Passkeys are filled by the 1Password browser extension, not by the system sheet. The Chrome Web Store build (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`) registers `inline/injected/webauthn-listeners.js` with `"world": "MAIN"`. That script replaces `navigator.credentials.create` / `get` in the page and talks to the extension over `postMessage`. Checked on webauthn.io: `credentials.create` is the extension's function, not the platform one. WebKit on this OS injects that main-world script. No app-side `ASAuthorizationController` is involved, and the browser passkey entitlement is not required.

The extension inside `/Applications/1Password.app` is not a web extension. `1Password Autofill Extension.appex` is an Authentication Services credential provider (`com.apple.authentication-services-credential-provider-ui`, `ProvidesPasskeys`). It has no `manifest.json`. `WKWebExtension` cannot load it. It only appears inside the system passkey sheet, which stays off. The Chrome build is the one that answers WebAuthn in the page.

The extension still has to be connected to the 1Password Mac app before it will create or sign in with a passkey. Native messaging to `1Password-BrowserSupport` does that. The helper accepts the parent only when the app is in `/Applications`, is not a symlink, and has a Developer ID signature with the hardened runtime. An ad-hoc debug build fails that check (`codeSignature` status 100001, `UnsupportedBrowser`). A Developer ID build of this tree, signed with only `com.apple.security.cs.allow-jit`, gets past verification. The extension's `NmRequestAccounts` and `NmAuthorizePartnerBrowser` then reach the helper. The helper asks the 1Password app to add the unknown browser. Until Marvin chooses that app in 1Password → Settings → Browser → Add Browser, the app returns `browser authorization failed` and a page ceremony is not completed.

The system sheet is prepared and gated off. WebKit would handle `navigator.credentials.create` / `get` itself only when the extension does not intercept. The ceremony would run in the web view that asked, so the Space's `WKWebsiteDataStore` keeps the cookies. Platform passkeys are not stored per profile. They live in iCloud Keychain or a credential provider. The app launches and browses with the system path off. A page that is not intercepted fails with `NotAllowedError` and no system sheet.

**Entitlement.** `com.apple.developer.web-browser.public-key-credential` (boolean) lets a browser make registration and assertion requests for any relying party, which a normal associated-domains entitlement does not do. Without it WebKit logs `AuthenticationServicesCore.AuthorizationError` code 1 ("Told not to present authorization sheet") and `ASAuthorizationError` code 1004, and the sheet never appears. It is a managed capability. Apple's criteria, which this app meets: HTTP and HTTPS are declared in Info.plist (`CFBundleURLTypes`), and on launch the window has an address field and search (⌘L / ⌘T) that navigate directly to the URL. `application(_:open:)` opens http(s) links in a tab in the current space.

The key is only in `myBrowser/myBrowser-passkeys.entitlements` (JIT plus the key). That file is not referenced by `project.yml` or `scripts/release.sh`. `myBrowser/myBrowser.entitlements` (the file Release signs) and `myBrowser/myBrowser-iCloud.entitlements` do not contain it. Checked on macOS 27.0.1: an ad-hoc signature with the hardened runtime and this key, and no profile, is SIGKILL (exit 137) before `main`. The same bundle with only `allow-jit` gets as far as dyld.

Switch on, in order, and not before:

1. Marvin, the Account Holder, submits <https://developer.apple.com/contact/request/macos-browsers-passkeys/>. Tim confirmed this request is pending.
2. Apple adds the capability to the App ID `ch.marvinvr.mybrowser` and issues a Developer ID provisioning profile that embeds `com.apple.developer.web-browser.public-key-credential`.
3. Point the signed file at the snippet. In `project.yml`, set Release `CODE_SIGN_ENTITLEMENTS` to `myBrowser/myBrowser-passkeys.entitlements`. In `scripts/release.sh`, pass that same file to `codesign --entitlements`. Embed the profile at `Contents/embedded.provisionprofile`. If Release is already signing `myBrowser/myBrowser-iCloud.entitlements`, add the same key to that file instead. The profile has to include every restricted entitlement in the signed file.
4. Ship. A signature that contains the key before that profile exists does not launch.

**User consent.** `ASAuthorizationWebBrowserPublicKeyCredentialManager` (`PasskeyBroker`). `authorizationStateForPlatformCredentials` is authorized, denied, or not determined. Reading that state is safe without the entitlement, and Settings still shows it. `requestAuthorizationForPublicKeyCredentials` runs only when `SecTask` reports the entitlement in this signature. Launch calls `requestAccessIfEntitled()` in that case. Settings → General → Allow Passkeys… is disabled otherwise, and `requestAccess()` returns without calling the system. The broker never reads credential material. WebKit still refuses the sheet until the profile grants the entitlement.

Classic password AutoFill inside `WKWebView` has no public macOS API. The Passwords app and 1Password show up as providers in the system passkey sheet, and as choices in AutoFill & Passwords. The 1Password extension covers password fill.

## Command bar

- Cmd+T: new tab mode (empty field). Cmd+L: edit current URL (prefilled, selected); Enter navigates the current tab.
- Results: "Open URL" when input looks like a URL, "Search <engine>" otherwise, plus matching open tabs / pinned sites in the current space (title or URL contains the query) → switch to them. A search-shaped query that names a split command ("split", "separate", "swap", "focus next", "focus previous") also lists that action when the selection can run it. "Open in Split View" leaves the bar open on the new pane.
- `URLInput.resolve(_:)` decides URL vs search. An explicit scheme is kept. `localhost`, IP addresses, a single label with `/` or a port (`photos/`, `coolify:8000`), `*.ts.net`, `*.local`, `*.internal`, `*.lan`, `*.home.arpa`, and any host with a port are `http`. A bare single label is `http` when it resolves and a search otherwise. Other `host.tld` values are HTTPS-first: one connection, certificate, or timeout failure falls back to `http` with the address-field "Not secure" mark, and never a confirm page. Relaxed hosts are not marked insecure. WebKit's known-host upgrade and user-mediated HTTPS fallback stay off.
- Default search engine: **Google** (enum `SearchEngine`: google, duckDuckGo, kagi, bing, ecosia). The choice is Settings → General, stored in `UserDefaults` under `SearchEngine.defaultsKey`.

## Keyboard shortcuts (Phase 1)

| Shortcut | Action |
|---|---|
| Cmd+T | Command bar, new tab |
| Cmd+L | Command bar, edit current URL |
| Cmd+W | Close the selected tab, or the focused pane when a split is selected (pinned/favorite: unload and reset to the saved URL; tabs: delete) |
| Cmd+Shift+T | Reopen last closed tab, including one the archiver just closed |
| Cmd+1…8 | Select n-th pane in navigable order (favorites, pinned (expanded), tabs). A split counts as its panes, not as one row. Cmd+9 = last |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous pane in that same order |
| Cmd+Opt+→ / ← | Next / previous space |
| Cmd+[ / Cmd+] | Back / forward |
| Cmd+R | Reload (`KeyMonitor` only; Ctrl+R does nothing) |
| Cmd+Shift+C | Copy link |
| Cmd+S | Hide / show sidebar |
| Cmd+Shift+I | Import bookmarks or an Arc sidebar |
| Cmd+D | Pin / unpin the current tab, or the whole split when a split is selected |
| Cmd+Shift+P | Enter or exit Picture in Picture |
| Ctrl+Cmd+S | Open in Split View. The selected site gains a new empty tab, which is focused and the command bar opens on it. A selected split with fewer than four panes gains that empty tab instead. ⌘⇧= is Zoom In on a US keyboard, so it is not used |
| Cmd+Shift+- | Separate the focused pane. Disabled unless a split has at least two panes. The split dissolves when one pane would remain |
| Cmd+Shift+\ | Swap the two panes. Disabled unless the split has exactly two |
| Ctrl+Opt+→ / ← | Focus the next / previous pane, wrapping. Disabled unless a split has at least two panes |
| Cmd+Shift+J | Downloads |
| Esc | Close command bar, downloads, or stop loading |
| ⌘⇧X | 1Password popup, when that extension is enabled in the space's profile. Other extension commands use the shortcut from their manifest. |
| ⌘⇧L | 1Password lock, when that extension is enabled |
| ⌘\\ | Reaches the page unless an extension command registered it. 1Password's inline menu listens for it. |
| Delete | Delete the focused folder. A non-empty folder asks first. Ignored while a field, the page, or the command bar is focused. |

## Sidebar drag and drop

The sidebar is a `VStack`/`ForEach`, not a `List`. Rows use `.draggable` and one `DropDelegate` (`onDrop`) so a drop can cross sections and nest. `LibraryStore.moveItem` stays same-space. Cross-space and nested drops go through `LibraryStore.move(_:toSpace:section:parentID:position:)` in `LibraryStore+Move.swift`.

- `move` takes a folder's or a split's live descendants with it in one batch: one `onChange`, one save. Descendants keep their parent links. Their `spaceID` and `section` change with the folder or the split. `canDrop` rejects a folder dropped into itself or a descendant, and rejects folders in favorites or tabs (those sections are sites only, at the root). A split cannot land in favorites or inside a split. A tabs split stays at the root. A member dragged out of its split clears fractions and dissolves the split when one pane is left. Dropping onto a split does not parent the dropped item into it.
- Dropping on a folder row inserts at the end of that folder. The folder expands after the pointer hovers there for about 0.6 s. Dropping between rows inserts before or after; the pointer's indentation picks the depth. An accent line (2 pt, rounded) marks the slot, inset to that depth. The dragged row fades. Its close button keeps its space and hides, so the title does not jump. Other rows reflow with `SidebarMotion.row`. Folder rows are plain buttons, like site rows: a tap gesture on the row would take the mouse-down and the folder would never start a drag. The expand click is ignored when a drag session is active or has just ended.
- The top and bottom 8 pt of a row stay the reorder line. The middle of a site or split row, while a loose pinned or tabs site is dragged, is a split drop instead: an accent wash and a `rectangle.split.2x1` icon, no insertion line. Dropping on a site groups the two pages and the split takes the target's place. Dropping on a split with fewer than four panes appends the dragged site. A folder, a favorite, a dragged split, a full split, and a horizontal favorites tile keep the previous before/after hit test. The sidebar selects one row, so there is no multi-select path into a split.
- Favorites accept sites only. Dragging between the tabs list and pinned pins or unpins. A link dragged from a page or another app (http/https only) becomes a new site at that slot. WebKit provides that link as an `NSURL`; the plain-text URL is the fallback. The insertion line clears when the drop is accepted. A link load finishes after that, and later updates from the same drop session do not bring the line back. A new tab in the current space is selected.
- Dropping on a space icon moves the item and its subtree. Sites and splits keep their section. Folders can only live in pinned, so they land there. The current space stays selected. A live tab that changes space is unloaded, because the destination profile has different cookies. An unpinned tab stores its page URL on the item. A pinned or favorite site keeps its home URL.
- Dragging a sidebar site over the content card's leading or trailing edge, or over the gap between split panes, previews that slot at half a pane. Dropping calls `createSplit` anchored on the page already showing, or `addToSplit` when a split is already there. The dragged page and the open page have to share a section. Four panes is the maximum, and the preview is absent then. Favorites, folders, other spaces, and panes that already belong to a different split are not accepted.
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
- **SidebarItem:** `spaceID`, `section`, `kind`, `parentID?`, `title`, `url?` (absolute string), `sortKey`, `isExpanded` (0/1), `splitFraction?` (number when finite and greater than zero, otherwise the key is cleared), `splitAxis?` (raw string, or cleared), `createdAt`, `modifiedAt`, `deletedAt?`. `library.json` still omits a nil fraction or axis. A CloudKit save always assigns both keys, including nil, so a reused record drops the previous value.

`.tabs` items are not mapped and are not uploaded, including a `.tabs` split and its members. A fetched `.tabs` record is ignored. A remote deletion whose local row is a tab is ignored. A pinned split and its members sync as normal `SidebarItem` records. Dissolving a pinned split tombstones the split and updates the surviving member. Focus is session state and is not a record field.

Synced rows are profiles, spaces, favorites, and pinned items (including folder trees and pinned splits). Tabs, `session.json`, favicons, and extensions stay on this Mac.

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
3. `project.yml`, Release only: set `CODE_SIGN_ENTITLEMENTS` to `myBrowser/myBrowser-iCloud.entitlements`. That file replaces `myBrowser/myBrowser.entitlements` and already includes `com.apple.security.cs.allow-jit`. It does not include the passkey entitlement. If passkeys are approved as well, add `com.apple.developer.web-browser.public-key-credential` to this file only when the same Developer ID profile grants it (see Passkeys). Leave Debug ad-hoc, with no iCloud entitlements.
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
- 2026-10-23: sidebar drag and drop uses `LibraryStore.move` (one batch, subtree included). A drop on a space icon keeps a site's section; folders land in pinned. A live tab that changes space is unloaded. An unpinned tab keeps its page URL. A pinned or favorite site keeps its home URL. A space swipe that is still tracking settles on a new outside touch, resign-key, or resign-active.
- 2026-10-23: folder rows drag as plain buttons. A link drop reads `NSURL` from the pasteboard and falls back to the plain-text URL. The row close button hides for the duration of a drag without leaving the layout.
- 2026-10-23: Chrome-family bookmarks and Arc sidebars import through an `ImportPlan` applied in one `LibraryStore` batch. Arc favorites (`topApps`) are copied onto every imported space of that profile. `Space.emoji` is optional so older library files still open.
- 2026-10-23: web extensions use `WKWebExtensionController`, one controller per profile id. Packages are unpacked under `Application Support/myBrowser/Extensions`.
- 2026-10-23: uBlock Origin (MV2, Chromium zip) installs through Settings → Extensions. Cosmetic filters run. Scriptlets use `tabs.executeScript`. Blocking `webRequest` does not, and there is no content-rule bridge yet (`docs/ubo-network-blocking.md`).
- 2026-10-23: trackpad haptics use `NSHapticFeedbackManager` through `Haptics`. One pulse per state change: space-swipe detent, history-swipe threshold, drop slot, pin/unpin, folder auto-expand, space drop target, and the drop.
- 2026-10-23: folder disclosure is a 0.2s no-bounce spring. Sidebar views read per-parent `SidebarSiblingList`s, so one toggle does not refresh the rest of the column.
- 2026-10-23: a split is one sidebar row (`SidebarItem.kind = .split`) whose panes are ordinary `.site` children, 2...4, ordered by `sortKey`. It lives in pinned or tabs, and may sit in a pinned folder. No nested splits, no folders inside a split. Dropping to one member dissolves the split: that site takes the split's place, a pinned split is tombstoned, and a tabs split is hard-deleted. Deleting the split deletes its members. `splitFraction` nil means equal widths; `splitAxis` nil means horizontal. Both are omitted from older `library.json` files. Focused pane is session-only (`focusedPaneBySplit`). Keyboard, Cmd+1…9, and extensions walk panes; the sidebar draws one row. `displayedContent` does not load web views. The first show of a split loads every pane; a later focus change does not resurrect an unloaded sibling. Remote apply does not dissolve a partial split. Unpinning into `.tabs` still does not emit a CloudKit delete. The content card lays those panes out, resizes them, and accepts a sidebar site dropped on an edge or between panes.
- 2026-10-23: the split row shows each pane's favicon and title. The middle of a row drop groups two sites, or adds a site to a split. ⌃⌘S opens a split with a new empty tab. The sidebar selects one row.
- 2026-10-23: closing a pinned split pane that was opened blank keeps the pane when the live tab has a URL. That URL and title become the pin's home, and the close is not added to recently closed. A pane that is still blank is deleted.
- 2026-10-23: a split keeps one section. A content drop anchors on the page already showing. A blank pane opened from a pin is a pinned site with no URL, and Close deletes it while the live tab has no URL either. A remote split that arrives with one pane stays until a later batch removes a member. CloudKit always writes `splitFraction` and `splitAxis`, including nil. A member whose container has not arrived is listed at the section root. The hover pill sits at the top trailing corner. The View menu and the split row toggle Side by Side and Stack Vertically. Separate, Swap, and Focus stay disabled when they would do nothing.
- 2026-10-23: the favorites grid balances rows (`ceil(n / maxPerRow)`, remainder on the earlier rows) so six icons are 3+3. Tiles in a row share its width. At most four per row, same as before.
- 2026-10-23: sidebar folders drop the disclosure chevron. Closed is `folder`, expanded is `folder.fill`, with a magic symbol replace in a fixed frame so rows stay aligned.
- 2026-10-23: downloads use `WKDownload` into `~/Downloads` (`file (1).pdf`, a `.download` partial, then a rename). The toolbar button shows active and recent items for the current profile. PDF, image, text, video, and audio open in a tab. Other types open in the default app.
- 2026-10-23: unpinned tabs archive after an idle interval (24 hours by default). Last-active times and the archive live in `session.json`, not on synced sidebar records. History → Archived Tabs… searches the last 30 days. ⌘⇧T still reopens the newest closed or archived tab.
- 2026-10-23: passkeys are filled by the 1Password Chrome extension (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`), which hooks `navigator.credentials` in the page. The 1Password.app credential-provider appex is not a web extension and is not loaded. The system sheet stays gated off. Marvin requests `com.apple.developer.web-browser.public-key-credential` (form pending, per Tim). The key stays out of `myBrowser.entitlements` and `myBrowser-iCloud.entitlements`. Only the unwired `myBrowser-passkeys.entitlements` has it, and nothing signs that file until the Developer ID profile embeds the capability. Allow Passkeys… does not call the system request unless the entitlement is in the signature. An ad-hoc hardened-runtime build with the key and no profile is SIGKILL exit 137. 1Password's helper accepts a Developer ID build in `/Applications` and then waits until that app is added under Settings → Browser. 1Password's Chrome extension (`aeblfdkhhhdcdjpifhhbdiojplfjncoa`) talks to the desktop app through stdio native messaging. On an ad-hoc debug build the helper starts and the extension reports `PortClosed`. The desktop app trusts the browser only after Settings → Browser → Add Browser on a Developer ID build in `/Applications`. This OS's WebKit needs testing mode plus a short service-worker prelude (`notifications`, `webNavigation.onCreatedNavigationTarget`, `storage.managed`) or 1Password's worker never finishes starting. Extension-page tabs load their URL. A popup-type extension window is a panel.
