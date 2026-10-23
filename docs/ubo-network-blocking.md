# uBlock Origin network blocking

uBlock Origin 1.75.0 (Manifest V2) installs from the Chromium zip. The background page, popup, options page, storage, and cosmetic filters run. Scriptlets go out through `tabs.executeScript`. It does not block network requests.

## Why the stock engine cannot

uBO cancels and redirects requests with `webRequest.onBeforeRequest` and the `blocking` extra. WebKit's `WKWebExtension` accepts the `webRequest` permission and then drops `blocking`. Listeners still run, and the return value (`{cancel:true}`, `redirectUrl`) is ignored. There is no public SPI that turns a `WKURLSchemeHandler` into an http(s) filter. `WKNavigationDelegate` only sees frame navigations.

`declarativeNetRequest` does block: WebKit compiles those rules into a `WKContentRuleList`. uBO MV2 does not emit DNR rules. uBO Lite does, and it is a different extension.

## What a bridge would be

Translate the static network lists already inside the installed package (EasyList, EasyPrivacy, uBO filters, Peter Lowe) into one or more `WKContentRuleList`s per profile.

- Attach them in `ProfileManager.configuration(for:)` and on web views that already exist, then reload http(s) pages the same way an injecting extension does.
- Cache with `WKContentRuleListStore`, keyed by a hash of the filter files plus the compiler version. Recompile when uBO updates a list.
- Cover the common forms only: `||host^`, `|scheme://`, path filters, `third-party`, and document-level exceptions. Skip scriptlets, redirects, CSP, `removeparam`, HTML filters, and procedural cosmetics. Those stay with uBO's own engine.
- Safari's `ignore-previous-rules` is not an ABP exception. A rule that should unblock one request can unblock every earlier rule. Exceptions need to be compiled as a narrower trigger, or left out.
- Stay under the content-blocker size limit (historically about 150k rules per list; several lists are allowed). Do not block `googlevideo.com` as a whole or YouTube stops playing.
- Dynamic per-site rules (the popup's "block this", trusted-site switch) do not apply until the list is compiled again.

That compiler is a separate project. A GPL converter exists (`bnema/ublock-webkit-filters`); don't vendor its output. Compile from the package the user installed.

Cosmetic filtering does not need this. It already runs through `tabs.insertCSS` once the compat shim is in the package. Scriptlets use `tabs.executeScript` on that same path.
