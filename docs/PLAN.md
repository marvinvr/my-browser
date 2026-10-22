# myBrowser: high-level plan

Opinionated macOS browser, Arc-style. Open source, public GitHub repo. iPhone later.

## Product (Marvin, 22.10.2026)
- macOS only for now. Native Swift, WebKit (WKWebView).
- Vertical sidebar like Arc:
  - Top: pinned sites as icons (favicon grid).
  - Below: pinned folders and sites, nested folders, drag & drop.
  - Below that: today's tabs (unpinned), cleaned up automatically like Arc (later, optional).
- Spaces: each Space has its own profile (own cookies/storage via `WKWebsiteDataStore(forIdentifier:)`), own pinned items, own color/icon. Switching Spaces by two-finger horizontal swipe on the sidebar + shortcuts.
- Horizontal two-finger swipe on the page/sidebar switches tabs (and back/forward stays on the page edge-swipe as in Safari; decide in Phase 1).
- iCloud sync of the sidebar (spaces, pinned items, folders) via CloudKit (`CKSyncEngine`), private database. Tabs/history not synced at first.
- Safari web extensions via `WKWebExtensionController` (macOS 15.4+ API). Install/enable per profile. uBlock Origin bundling: later, not now.
- Import:
  - Chrome (and Chromium browsers: Brave, Edge, Arc-as-Chromium) bookmarks → sidebar folders.
  - Arc: everything from `~/Library/Application Support/Arc/StorableSidebar.json`: spaces (name, icon, color, profile mapping), pinned/favorites, folders (nested), pinned tabs.
- Feel: native macOS, Liquid Glass, smooth spring animations, good icons (SF Symbols + custom app icon), minimal chrome. Command bar (Cmd+T / Cmd+L) for URL + search + open tabs. Only what's needed.
- Out of scope for now: iPhone, uBlock bundling, history sync, password manager (use iCloud Keychain AutoFill if WebKit allows), reading mode, AI features.

## Tech decisions
- Swift 6, SwiftUI with AppKit where needed (NSWindow tweaks, gestures, WKWebView hosting). Min macOS 26 (Liquid Glass, latest WebKit APIs).
- XcodeGen (`project.yml`), like Dusk. No checked-in .xcodeproj churn.
- Model: SwiftData (local) with a sync layer on CKSyncEngine; or a plain Codable store + CKSyncEngine. Phase 1 lead decides and writes it down in `docs/architecture.md`.
- Signing: ad-hoc/local first. Developer ID, iCloud container entitlements and notarization are a later step (Tim Apple).

## Orchestration
- Molty: high-level phases, spawns one Claude (Opus) lead per phase/workstream, reviews results, reports to Marvin.
- Claude leads: plan their workstream, split it into small clear tasks, delegate the coding to **Grok High** agents via mmux (`mmux new agent "Grok High" --prompt ...`, `mmux wait`), review diffs, integrate, verify (build, run, screenshots). Claude codes itself only for glue/UI taste or when Grok fails twice.
- Each lead works in its own worktree when running in parallel; merges to main itself after review (direct push to main is fine for this repo).

## Phases
1. **Foundation** (one lead, serial): repo scaffold, XcodeGen, architecture doc, data model (Space, Profile, SidebarItem tree: pinned icon / folder / site / tab), window shell with sidebar + WKWebView tabs, tab switching, Spaces with separate data stores, command bar, basic persistence. Runs and is usable for daily browsing basics.
2. **Parallel workstreams** (after Phase 1, each its own lead + worktree):
   - A. Sidebar UX & feel: pinned icon grid, nested folders, drag & drop, context menus, animations, swipe gestures for tabs/spaces, app icon.
   - B. Importers: Chrome/Chromium bookmarks, Arc full import (spaces, pins, folders) with a nice import flow.
   - C. Extensions: WKWebExtension support (install .appex/web-extension folders, toolbar buttons in the sidebar, popups, per-profile enable).
   - D. iCloud sync: CKSyncEngine for the sidebar model, conflict handling; needs entitlements → coordinate with signing.
3. **Polish & release**: crash/perf pass, settings, onboarding (import on first launch), signing + notarized DMG + Sparkle (Tim for certificates), README/screenshots.
