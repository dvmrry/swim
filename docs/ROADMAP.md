# swim — Roadmap

## Current State

Minimalist vi-mode browser for macOS. ~5,100 LOC, 217KB binary.
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
- Test server mode (HTTP API: actions, commands, screenshots)

---

## Phase 1: AI-Native Browser Platform

**Goal:** Make swim the first browser built for both human and AI operators.

### 1.1 MCP Server Mode (`swim --mcp`) ✓ Shipped
Expose swim as an MCP (Model Context Protocol) server so Claude Code,
Cursor, and other MCP clients can use it as a real browser tool.

**MCP tools to expose:**
- `navigate(url)` — open URL in active tab
- `screenshot()` — capture current page as PNG
- `extract()` — return page content as structured text/markdown
- `execute(command)` — run any `:command`
- `action(name)` — trigger any keybinding action
- `state()` — return current mode, URL, tab list, title
- `tabs()` — list all open tabs
- `find(query)` — search page content

**Why this matters:** Every other MCP browser tool spawns a separate
Chromium instance with no user config. swim gives AI access to *your*
browser — your sessions, bookmarks, adblock, dark mode, userscripts.

### 1.2 Profiles (`swim --profile <name>`)
Different default configs for different use cases. Same binary, same code.

- `default` — current minimal vi-mode setup
- `casual` — tab bar always, larger fonts, visible status bar
- `headless` — no window, API-only (for batch/automation)

Profile = config file overlay, not code branches.

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

## Phase 2: AI Copilot Mode

**Goal:** Bidirectional AI assistance while browsing.

### 2.1 AI Copilot (`:ai <prompt>`)
AI watches page context (URL, title, content) and responds with
browser actions through the same command/action dispatch system.

- `:ai summarize` — extract and summarize current page
- `:ai find pricing` — navigate to pricing page
- `:ai fill form` — fill form fields from context
- `:ai compare tabs` — compare content across open tabs

The AI uses the same commands you do. No special API needed.

### 2.2 Passive Suggestions
AI observes browsing patterns and surfaces suggestions in status bar:
- "3 tabs on same domain — close duplicates?"
- "This page has a reader mode — press :focus"
- "Login page detected — check password manager?"

Opt-in, dismissable, non-intrusive.

### 2.3 Session Recording/Replay
Every action flows through `handle_action`, so recording a session
is logging actions with timestamps. Replay is posting them back.

- `:record start/stop` — capture action sequences
- `:replay <name>` — replay a recorded session
- Export as shell script (curl commands to the API)

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

*Last updated: 2026-03-09*
