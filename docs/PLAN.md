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
- Extensions: they just have to work, the source doesn't matter (Marvin 22.10.). Plan: WebKit's `WKWebExtensionController` (macOS 15.4+), which loads standard WebExtensions (MV2/MV3) from a folder or zip, so besides Safari extensions also unpacked Chrome Web Store (.crx) and Firefox (.xpi) extensions can be installed. Install/enable per profile. uBlock Origin bundling: later, not now.
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

## Orchestration (Marvin's rules, binding for every agent)
- **All code is written by Grok High agents. Grok xHigh only for really complex tasks where Grok High clearly fails. No Codex, no Claude coding.**
- **One Claude lead for the whole project, orchestration only**: plans, writes task prompts, spawns Grok High agents via mmux, waits, hands reviews to another Grok High, reads only short verdicts. It never writes code or project files. Claude usage must stay minimal.
- Molty: high-level phases, keeps the single Claude lead on track, reports to Marvin.
- Parallel work = several Grok High agents (own worktrees when files overlap); direct push to main after a Grok High review.
- Details: AGENTS.md.

## Phases
1. **Foundation** (one lead, serial): repo scaffold, XcodeGen, architecture doc, data model (Space, Profile, SidebarItem tree: pinned icon / folder / site / tab), window shell with sidebar + WKWebView tabs, tab switching, Spaces with separate data stores, command bar, basic persistence. Runs and is usable for daily browsing basics.
2. **Parallel workstreams** (after Phase 1, same single Claude lead, each workstream done by Grok High agents in its own worktree):
   - A. Sidebar UX & feel: pinned icon grid, nested folders, drag & drop, context menus, animations, swipe gestures for tabs/spaces, app icon.
   - B. Importers: Chrome/Chromium bookmarks, Arc full import (spaces, pins, folders) with a nice import flow.
   - C. Extensions: WKWebExtension support: install from the Chrome Web Store (download + unpack .crx), from .xpi/.zip/folder, and installed Safari extensions where possible; toolbar buttons in the sidebar, popups, permissions, per-profile enable.
   - D. iCloud sync: CKSyncEngine for the sidebar model, conflict handling; needs entitlements → coordinate with signing.
3. **Polish & release**: crash/perf pass, settings, onboarding (import on first launch), signing + notarized DMG + Sparkle (Tim for certificates), README/screenshots.
