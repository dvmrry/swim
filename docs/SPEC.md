# swim (Swift) — Kickoff Spec

This is the starting spec for a clean-room Swift rewrite of swim. The C/ObjC
implementation lives on, archived, at **github.com/dvmrry/swim-c** (tag `c-final`) —
it is the reference implementation and test oracle. Read this before writing code.

---

## Why a rewrite, and what it is not

The C version exists because C was the portable choice for Linux + macOS. That
reason is gone: swim is macOS-only, the author writes Swift daily (a Swift WM is in
progress), and Xcode + a signing key are available. The C version is finished and
stable; the Swift version is a fresh build, not a translation.

**Not:** an agent-browser platform. The C version once had a 25-endpoint HTTP API +
MCP sidecar reimplementing a subset of CDP via JS injection. It was deleted on
purpose — Playwright / Chrome CDP do that better. Agent browsing happens in Chrome
(dedicated profile, CDP on localhost, driven by CLI tools). Do not rebuild it.

**Is:** a minimalist, keyboard-driven, vi-modal WKWebView browser that the author
daily-drives, with clean native macOS integration.

---

## Hard requirement: data compatibility

The Swift build must be a **drop-in replacement** that reads an existing
`~/.config/swim/` unchanged on first launch. Do not invent new formats for these.

| File | Format |
|---|---|
| `config.toml` | TOML-ish INI. Sections `[general]` (homepage, search_engine, restore_session, dark_mode), `[appearance]` (font_size 8–32, tab_bar / status_bar = `"always"\|"never"\|"auto"` — also accept legacy true/false, theme, compact_titlebar), `[adblock]` (enabled), `[search]` (`<prefix> = "<url template with %s>"`), `[proxy]` (type `http\|socks5`, host, port), `[keys.normal]` (`<keys> = "<action>"`). Written back by `:set`. |
| `profiles/<name>.toml` | Same format; overlays the base config (`--profile <name>`). |
| `history.json`, `bookmarks.json` | JSON array of `{"url","title","time"}` (time = unix seconds). Adding fields (e.g. `visitCount`) is fine if old files still load with defaults. |
| `session.json`, `session-<name>.json` | JSON array of URL strings. |
| `zoom.json` | JSON object `host → zoom` (e.g. `{"old.reddit.com":0.90}`); hosts at 1.0 are not stored. |
| `themes/*.theme` | `key = #rrggbb` lines, `#` comments. Keys: `bg status-bg fg fg-dim normal insert command hint passthrough accent` (note the hyphens). Tokyo Night + Kanagawa ship as defaults, created on first run. |
| `scripts/*.js` | Greasemonkey-style header (`// ==SwimScript==` … `@name`, `@match` (multiple, `<all_urls>` supported), `@run-at document-start\|document-end`, `// ==/SwimScript==`). `*.js.disabled` = off. |

The C repo's `test/storage_test.c` and `test/zoom_test.c` encode format edge cases
(title-less entries, timestamp overflow, truncated files, quote/backslash
round-trips, forget-zoom-at-1.0) — port them as Swift tests first.

---

## Feature parity checklist (acceptance criteria)

**Modes:** NORMAL, INSERT (auto-entered on input focus), COMMAND (`:`), HINT,
PASSTHROUGH (Ctrl-V toggles; all keys go to the page). Esc returns to NORMAL.
Count prefix (`5j`), repeat last action (`.`).

**Default NORMAL bindings** (all rebindable via `[keys.normal]`):

| Keys | Action | Keys | Action |
|---|---|---|---|
| `j` `k` `h` `l` | scroll-down/up/left/right | `G` / `gg` | scroll-bottom / scroll-top |
| Ctrl-D / Ctrl-U | scroll-half-down/up | Ctrl-F / Ctrl-B | scroll-full-down/up |
| `d` / `u` | close-tab / undo-close-tab | `J` / `K` | prev-tab / next-tab |
| `H` / `L` | back / forward | `r` | reload |
| `o` / `O` | command-open / -open-current | `t` / `T` | command-tabopen / -tabopen-current |
| `f` / `F` / `;y` | hint-follow / hint-tab / hint-yank | `/` `n` `N` | find / find-next / find-prev |
| `yy` / `yp` | yank-url / yank-pretty-url | `pp` / `Pp` | paste-open / paste-tabopen |
| `gt` | goto-tab | `<<` / `>>` | move-tab-left/right |
| `gu` / `gU` | navigate-up / navigate-root | `:` `.` | enter-command / repeat-last |

Cmd+= / Cmd+- / Cmd+0: zoom in / out / reset (0.3–3.0, step 0.1), **persisted per
domain** and re-applied on navigation (unknown hosts reset to 1.0).

**Commands** (`:name` / alias): `open o`, `tabopen to`, `quit q`, `adblock`,
`bookmark bm`, `marks` (search bookmarks), `history`, `set`, `settings`,
`passthrough`, `focus` (reader mode), `session` (save/load named), `tabs`,
`tabclose tc`, `tabonly`, `scripts` (list/reload), `help h`, `private p`,
`darkmode dm`, `mute`, `devtools`, `proxy`. Tab completes command names; in
`:open`/`:tabopen` Tab cycles URL candidates (bookmarks first, then history,
deduped, wraps).

**URL handling:** `g foo` → search-shortcut expansion from `[search]`; bare words
(no `.` or `/`) → default search engine; block `javascript:`, `data:`, `file:`.
Variable substitution `{url}` `{title}` `{clipboard}`.

**Everything else:** tabs + tab bar (always/never/auto), status bar with mode +
URL (lock glyph on https), bookmarks, history, named sessions + restore on launch,
find-in-page, adblock (WKContentRuleList), userscripts, reader/focus mode (themed),
themes, downloads to ~/Downloads with filename dedup, native file upload
(NSOpenPanel), clipboard, dark mode (prefers-color-scheme), tab mute, devtools,
HTTP/SOCKS5 proxy overriding system, private tabs (non-persistent data store),
`--app <url>` (chromeless single window, keys pass through), `--profile <name>`,
`swim url1 url2 …` opens tabs.

**Reuse as-is:** the injected JS in swim-c's `js/` — `hints.js`, `focus.js`
(reader mode), `dark-mode.js`, `old-reddit.js`, `youtube-adblock.js`. A large share
of swim's behavior is this JS; copy it, don't rewrite it.

---

## Day-one architecture

1. **One typed command layer.** Every user-visible operation is a typed command
   (an enum or protocol, not strings). Keybindings, the command bar, and any future
   App Intent or tool all call the same layer. This was the C version's rule
   ("everything flows through handle_action/registry_exec"); make it structural.
2. **Design for five read-mostly capabilities** — the things only swim knows:
   current tab (url/title), current page as text (reuse reader-mode extraction),
   list tabs, search history/bookmarks, open URL. Not exposed on day one — just
   shaped so an **App Intents** adapter (first) or a thin local tool for an agent
   (second, only if actually wanted) is a few dozen lines later. Never click/fill/
   drag automation.
3. **Signed `.app` bundle from the start.** Stable signing identity keeps macOS
   privacy grants across rebuilds and enables entitlements (keychain autofill,
   App Intents). Choose Xcode project or SwiftPM + bundling script — either is fine.
4. **Swift-native persistence.** Codable models for the formats above; no
   hand-rolled parsers (the C JSON parser needed patching twice).
5. **Frecency from the start.** History entries carry visit count + last visit;
   completion ranks by `visitCount × recency` (buckets ≈ <1h ×4, <1d ×3, <1wk ×2,
   <1mo ×1, else ×0.5; bookmarks get a bonus). Later: a small visible candidate list
   under the command bar. Evict lowest-frecency at the history cap.
6. **Session autosave.** Save the session on tab open/close/navigate, not only on
   clean quit — a crash must not lose tabs. (The C version only saved on quit.)
7. **Keep shareable pieces separable.** The key trie, config parser, and theme
   system could later be shared with the author's Swift WM — build them as clean
   modules with no AppKit dependency.

**WKWebView lessons from the C version:** `navigationDelegate` is weak — keep a
strong reference per tab. Inject CSS at document-start (no flash), DOM-touching JS
at document-end. Use a local key-event monitor for global keys; skip it in `--app`
mode. Auto-reload a tab when its web content process crashes.

---

## Non-goals

- Agent-browser platform / automation endpoints / MCP server (see top).
- WebExtensions / Chrome extension compatibility.
- Feature parity with Chrome/Firefox — minimalism is the product.
- Web-based browser chrome — UI stays native AppKit (or SwiftUI where it fits).
- Cross-platform.

**Size budget:** stay small. The C version was ~280KB and under 10K LOC; if the
Swift version balloons, something is being over-engineered.

---

## Working practice

- Keep swim-c as the daily driver until the Swift version reaches the parity list
  above; then switch. Don't switch at "mostly works."
- Test the persistence layer against real `~/.config/swim/` files early.
- UI behavior needs runtime verification (run the app); don't claim UI features work
  from compiling alone.
- Commits: no `Co-Authored-By` lines.

*Written 2026-10-10 from the final state of swim-c.*
