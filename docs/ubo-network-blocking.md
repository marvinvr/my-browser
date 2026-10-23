# uBlock Origin network blocking

Full uBlock Origin (Manifest V2, Chromium zip) blocks network requests through WebKit content rules. Cosmetic filters and scriptlets still go through `ExtensionWebKitCompat` (`tabs.insertCSS`, `tabs.executeScript`). uBO Lite is left alone: it already ships `declarativeNetRequest` rules, and a second compiler would double-block.

## Why this is not `webRequest`

uBO cancels requests with `webRequest.onBeforeRequest` and the `blocking` extra. `WKWebExtension` accepts the permission and then drops `blocking`. `{cancel:true}` and `redirectUrl` are ignored. There is no public SPI that turns a `WKURLSchemeHandler` into an http(s) filter, and `WKNavigationDelegate` only sees frame navigations. `declarativeNetRequest` does block, but uBO MV2 does not emit those rules.

## What the bridge does

`ContentBlockerController` reads the installed package (the extension whose name is `uBlock Origin` and that contains `assets/assets.json`). For each profile where it is enabled:

- Enabled lists come from `browser.storage.local` (`selectedFilterLists`). When that key is absent, the default is every `assets.json` filter list that is not `off`, plus user filters. List bodies are the cached storage value (`cache/<key>`, including uBO's `UOSC_1` and `UOSC/lz4_1` forms) or, if that is missing, the package file. Nothing is downloaded.
- User filters and the trusted-site list (`netWhitelist` or `data.whitelist`) are included. The popup power button writes that list. A hostname becomes `ignore-previous-rules` with `if-domain` for that host and its subdomains, placed after `$important` so the site actually turns off.
- Static network filters are translated to content-blocker JSON: `block`, `block-cookies`, `css-display-none`, and `ignore-previous-rules` for `@@`. Triggers use `if-domain`, `unless-domain`, `resource-type`, and `load-type`. `if-domain` and `unless-domain` match the top document (`$domain`).
- Lists are split at 150,000 rules, at most 8 lists. Exceptions, `$important`, and the whitelist are copied into every chunk, in that order, so an exception can cancel a block in the same list. Simple cosmetics are dropped first when a chunk would overflow, then unanchored network rules.
- Rules that would over-block are dropped and counted: redirects, CSP, `removeparam`, scriptlets, procedural cosmetics, entity domains (`example.*`), named cookies, host-wide `googlevideo.com` (a path on that host is kept), and anything whose only resource type WebKit cannot name. `reason=` is ignored. WebKit's matcher rejects `|` in `url-filter`, so an ABP `^` is a separator character and does not also match the end of the URL.
- Translation runs off the main actor. `WKContentRuleListStore.compileContentRuleList` stays on the main actor. A private store lives under `ContentBlocker/store` in the library directory. The cache key is a hash of the compiler version, the probed trigger support, each list's raw cache bytes, the decoded text, the user filters, and the sorted whitelist. A matching sidecar is reused. Storage is polled every 2 seconds (database and WAL mtimes) and debounced 400ms, so a list update or a power-button toggle recompiles. Existing web views for that profile, including `window.open` and the download auxiliary view, get the new lists. Open http(s) tabs reload only when the applied hash changes.

`load-context`, `if-top-url`, `websocket`, a starred `if-domain` (`*example.com`), and `if-domain` together with `unless-domain` are probed once per launch. A trigger this WebKit rejects is not emitted. Subdocument-only rules are dropped when `load-context` is unavailable, instead of blocking the top navigation. Websocket-only rules are dropped.

## What stays with uBO

Scriptlets, redirects, CSP injection, `removeparam`, HTML filtering, and procedural cosmetics are not content rules. The compat shim still injects cosmetic CSS and scriptlets. A request that ends exactly on a filter token, with no separator after it, is not matched. Host-wide `googlevideo.com` rules are dropped so YouTube playback keeps its media host.

## Measured

On the default uBO 1.75 lists (storage empty, so the package defaults), one cold compile produced `lines=202621 converted=181059 kept=181059 emitted=184781 chunks=2 dropped=21645` in 10.9s with no WebKit parse errors. The tail is copied into both chunks, which is why emitted is larger than kept. The same set with one trusted site was `kept=181060 emitted=184783` in 11.0s. This WebKit accepts `load-context`, `if-top-url`, `websocket`, and a starred domain, and rejects `if-domain` together with `unless-domain` (`lc1-top1-ws1-star1-and0`). The largest drop is scriptlets (10735), then cosmetic filters WebKit cannot express. Turning a site off in the popup recompiles and the next load of that site skips the compiled blocks; removing it blocks again. `ignore-previous-rules` only cancels earlier rules in the same list, which is why the tail is repeated.
