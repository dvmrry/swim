# Userscript System — Design

**Goal:** Load site-specific scripts from `~/.config/swim/scripts/` with Greasemonkey-compatible headers, replacing hardcoded Reddit/YouTube scripts in `ui.m`.

## Script Format

Standard JS with Greasemonkey header. Parse `@name`, `@match`, `@run-at`; ignore everything else.

```js
// ==UserScript==
// @name        Old Reddit Cleanup
// @match       *://old.reddit.com/*
// @run-at      document-start
// ==/UserScript==
```

`@run-at`: `document-start` → `WKUserScriptInjectionTimeAtDocumentStart`, `document-end` (default) → `AtDocumentEnd`. `@match` uses standard pattern format (`*://`, `*` wildcards in host/path).

## Architecture

- New: `userscript.c` / `userscript.h` — header parser, directory scanner, match pattern compilation
- `ui.m` — at webview creation, inject matching scripts as `WKUserScript` based on `@match` and `@run-at`
- `main.m` — call loader at startup, register `:scripts` and `:scripts reload` commands
- Core scripts (focus detection, hints) stay in `ui.m` — not site-specific
- Old Reddit (CSS + JS combined) and YouTube adblock move to default scripts

## Default Scripts

First run (directory doesn't exist): create `~/.config/swim/scripts/` with:
- `old-reddit.js` — CSS injection + sidebar toggle
- `youtube-adblock.js` — ad hiding + MutationObserver skip

## Enable/Disable

File presence = enabled. Rename to `.js.disabled` to disable.

## Commands

- `:scripts` — list loaded scripts and match patterns
- `:scripts reload` — rescan directory, apply to new page loads
