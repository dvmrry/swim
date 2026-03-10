# swim — Roadmap

## Current State

Minimalist vi-mode browser for macOS. ~6,100 LOC, single binary.
C/Objective-C, Cocoa + WKWebView. Single developer, AI-assisted.

### Shipped
- Modal editing (NORMAL/INSERT/COMMAND/HINT/PASSTHROUGH)
- Tabs, bookmarks, marks, history, session save/restore
- Find-in-page (/, n, N), hint follow/tab/yank (f, F, ;y)
- Adblock (WKContentRuleList), userscripts, reader/focus mode
- Themes, config (INI), custom keybindings (key trie)
- Downloads (~/Downloads with dedup)
- Zoom, clipboard integration (yy, yp, pp, Pp)
- Navigate up/root (gu, gU), search engine shortcuts
- Dark mode (prefers-color-scheme), tab mute, devtools
- Proxy (HTTP/SOCKS5, overrides system), private tabs
- Variable substitution ({url}, {title}, {clipboard})
- Count prefix (5j), repeat last action (.)
- HTTP API server (`swim --serve <port>`) with 25 endpoints
- MCP sidecar (`swim-mcp`) for Claude Code / Cursor integration
- File upload (native NSOpenPanel via WKUIDelegate)

---

## Phase 1: AI-Native Browser Platform

**Goal:** Make swim the first browser built for both human and AI operators.

### 1.1 MCP Server Mode (`swim --mcp`) ✓ Shipped
Expose swim as an MCP (Model Context Protocol) server so Claude Code,
Cursor, and other MCP clients can use it as a real browser tool.

**MCP tools exposed (single meta-tool with `method` param):**
- `navigate(url)` — open URL, wait for load, return state
- `screenshot()` / `pdf()` — capture page as PNG or PDF
- `extract()` — structured text/markdown with links and metadata
- `interact()` — discover form fields, buttons, selects with selectors
- `fill(selector, value)` / `select(selector, text)` — form automation
- `click(selector|text)` / `hover(selector)` / `drag(from, to)`
- `query(selector)` — read element attributes and text
- `wait_for(selector|url_contains|idle)` — poll for conditions
- `execute(command)` / `action(name)` / `key(key)` / `eval(js)`
- `state()` / `tab(index)` / `navigate_back()` / `navigate_forward()`
- `scroll(selector)` / `storage(type)` / `console()` / `dialog()`

**Why this matters:** Every other MCP browser tool spawns a separate
Chromium instance with no user config. swim gives AI access to *your*
browser — your sessions, bookmarks, adblock, dark mode, userscripts.

### 1.2 Profiles (`swim --profile <name>`) ✓ Shipped
Config file overlays at `~/.config/swim/profiles/<name>.toml`.
Same binary, same code — profile just overrides base config values.

- `casual` — tab bar always, larger fonts, visible status bar
- `minimal` — hide everything, maximum content space
- Custom profiles: create any `<name>.toml` in the profiles directory

### 1.3 Content Extraction API ✓ Shipped
GET /extract returns structured page content, not just screenshots.

- Article text (reader-mode extraction)
- Links with context
- Form fields and their state
- Page metadata (title, description, OpenGraph)
- Selected text

### 1.4 Pipe Interface
```
echo "open https://example.com" | swim --pipe
swim --pipe --screenshot | imgcat
curl -s api.example.com | swim --pipe --render
```
Unix philosophy: stdin commands, stdout results.

---

## Phase 2: Automation & AI

**Goal:** Teach swim workflows, replay them, bring AI in only when needed.

### 2.1 Event Stream (`/events`)
Server-Sent Events endpoint. swim pushes actions as they happen:
navigation, form fills, clicks, page loads, console errors. Foundation
for recording, replay, and live AI observation. Cheap to build —
`handle_action` is already the single chokepoint.

### 2.2 Session Recording/Replay
Every action flows through `handle_action`, so recording is logging
the event stream with timestamps. Replay is posting actions back.

- `:record start/stop` — capture action sequences
- `:replay <name>` — replay a recorded session
- Export as workflow JSON or shell script

### 2.3 Workflow Sidecar (swim-auto)
Lightweight state machine that subscribes to the event stream and
executes known workflows without LLM calls. Portable JSON workflow
files: trigger condition + ordered steps (wait, fill, click).

Claude only gets called to:
- Build a new workflow from a recording ("I watched you do this — here's the pattern")
- Handle unexpected page states ("new captcha field appeared")
- Answer ad-hoc questions about page content

No tokens burned on repetitive work. The sidecar acts, Claude teaches.

### 2.4 AI Copilot (`:ai <prompt>`)
Direct Claude integration for ad-hoc page interaction:

- `:ai summarize` — extract and summarize current page
- `:ai fill form` — fill form fields from context
- `:ai compare tabs` — compare content across open tabs

Uses the same commands/actions the user does. No special API.

---

## Phase 3: libswim

**Goal:** Extract the core into a reusable library.

### Architecture

```
libswim.a / libswim.dylib
├── browser.c    — tab state, tab collection
├── input.c      — modal key handling, key trie
├── commands.c   — command registry, completion
├── config.c     — config parser
├── storage.c    — bookmarks, history, sessions
├── userscript.c — script loader
├── theme.c      — theme system
├── focus.c      — reader mode
└── api.c        — HTTP/MCP server (extracted from test_server)

swim (binary)
├── main.m       — thin shell: NSApp, event monitor, action wiring
└── ui.m         — Cocoa UI (window, tab bar, status bar, webviews)
```

**The split:** libswim is pure C — already ~70% of the codebase.
The platform/engine layer is the remaining ~30%.

```
libswim (pure C, portable)
├── browser.c, input.c, commands.c, config.c
├── storage.c, userscript.c, theme.c, focus.c
└── api.c (HTTP/MCP server)

Platform backends:
├── macOS:    Cocoa + WKWebView  (current, ships today)
├── Linux:    GTK + WebKitGTK    (same engine, different platform)
└── Chromium: CEF                (different engine entirely)
```

The Tab struct already uses `void *webview` — engine-agnostic by design.
Each backend implements: create webview, navigate, run JS, screenshot.
The core doesn't know or care what renders the page.

**API surface:**
```c
// Core
Browser *swim_browser_create(void);
ModeManager *swim_mode_create(ActionFn callback);
CommandRegistry *swim_commands_create(void);
Config *swim_config_load(const char *path);

// Server
SwimServer *swim_server_start(int port, SwimContext *ctx);
SwimMCP *swim_mcp_start(SwimContext *ctx);
```

**When to do this:** When there's a second consumer (e.g., Linux port,
headless tool, or someone embedding swim in another app). Premature
extraction adds complexity without value. The current single-binary
architecture is an asset — don't split until splitting solves a real problem.

---

## Maturity Roadmap

### Dialog Handling ✓ Shipped
Auto-respond to alert/confirm/prompt when serving. Queued for agent polling via `/dialog`.

### Iframe Support (Partial ✓)
Same-origin: ✓ shipped — extract content, report interactables, allow subframe nav.
Cross-origin: `WKUserScript` with `forMainFrameOnly:NO` + message passing.
Enterprise apps (Oracle, SAP) are iframe-heavy — needed for full LOB coverage.
Also enables iframe-based ad/tracker killing (size heuristic: 1x1 pixels, 300x250 ad slots
from third-party origins). Debug use case: diagnose Safari PAC proxy + iframe URL mangling.

### File Upload ✓ Shipped
Native NSOpenPanel via `runOpenPanelWithParameters:` WKUIDelegate for interactive use.
Programmatic upload via `/upload` endpoint and MCP `upload` method — sets file inputs
via DataTransfer API (base64 data, filename, MIME type).

### Network Request Inspection ✓ Shipped (JS Layer)
`/requests` injects fetch/XHR wrapper that captures method, URL, status,
timing for JS-initiated requests. First call installs hooks, subsequent
calls drain the buffer. Covers the 90% automation case (API calls, form
submissions, AJAX). Does not capture image/CSS loads or protocol metadata.

**Future: Full Network Inspection (WebKit Inspector Protocol)**
WKWebView has an undocumented inspection protocol (same family as Chrome
DevTools Protocol). Accessible via `_WKInspector` private APIs or
`com.apple.webinspector` XPC service. Would give full headers, timing
waterfall, protocol version, response bodies — equivalent to Safari's
Network tab but programmatic. Private API (not App Store safe, could
break on macOS updates). Protocol source is in WebKit repo. Worth
exploring when JS-level capture proves insufficient.

### Drag and Drop ✓ Shipped
`/drag` dispatches mousedown/mousemove/mouseup + HTML5 drag events between two selectors.

### JS-Heavy Page Extraction ✓ Shipped
`/extract` falls back to `innerText` when markdown conversion returns <100 chars.

---

## Non-Goals

- Extension API compatibility (WebExtensions, Chrome extensions)
- Feature parity with Chrome/Firefox (minimalism is the product)
- Electron/web-based UI (native platform UI only)

## Architectural Rules

1. **Core never imports platform headers.** `browser.h`, `input.h`,
   `commands.h`, `config.h`, `storage.h` stay pure C. No Cocoa, no GTK,
   no WebKit. Platform code lives only in `main.m` and `ui.m` (or their
   equivalents on other platforms).

2. **Webview is opaque.** The `void *webview` in Tab is the only bridge
   between core and platform. The core tracks state, the platform renders.

3. **Actions and commands are the API boundary.** Everything the user or
   AI can do flows through `handle_action` or `registry_exec`. New
   features should be actions/commands, not one-off UI hooks.

4. **The wrapper is thin.** Platform backends implement: create window,
   create webview, navigate, run JS, screenshot, handle events. The core
   handles everything else.

## Size Budget

The browser should stay under 500KB and 10K LOC for the core.
If it's getting bigger, something is being over-engineered.
The 300MB browsers got there one "reasonable" feature at a time.

---

*Last updated: 2026-03-10*
