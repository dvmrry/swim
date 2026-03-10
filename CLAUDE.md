# swim

Minimalist vi-mode web browser for macOS, written in C/Objective-C (Cocoa + WebKit).

## Build

```
make        # builds ./swim
make clean  # removes binary
```

## Project Structure

- `main.m` — app lifecycle, event monitor, action dispatch, command handlers
- `ui.m` / `ui.h` — window, tab bar, status bar, command bar, webview management
- `input.c` / `input.h` — modal key handling (NORMAL/INSERT/COMMAND/HINT/PASSTHROUGH), key trie
- `commands.c` / `commands.h` — command registry with tab completion
- `browser.c` / `browser.h` — tab collection, URL/title state
- `storage.c` / `storage.h` — bookmarks, history, session persistence
- `config.c` / `config.h` — INI config parser, key bindings
- `js/` — reference copies of injected userscripts

## API Server

```
swim --serve          # Unix socket at ~/.config/swim/swim.sock (default)
swim --serve 9111     # TCP port 9111
swim --serve /tmp/s   # Unix socket at custom path
swim --profile casual # load ~/.config/swim/profiles/casual.toml overlay
```

Endpoints: /health, /state, /screenshot, /pdf, /extract, /interact, /click, /hover, /drag, /fill, /upload, /select, /query, /scroll, /storage, /console, /dialog, /requests, /tab, /wait, /wait_for, /action, /command, /key, /eval, /batch, /resize

## MCP Integration

```
swim-mcp              # connects via Unix socket (default)
swim-mcp --port 9111  # connects via TCP
```

Tools: navigate, screenshot, extract, interact, fill, upload, select, query, scroll, storage, tab, wait_for, execute, action, state, click, key, hover, console, navigate_back, navigate_forward, pdf, eval, drag, dialog, requests

Notes:
- `navigate` waits for page load (polls until title is non-empty, up to 5s) and returns full page state
- `wait_for` supports `idle:true` to wait for page stability (readyState complete + no DOM mutations for 500ms)
- Dialog auto-response: alerts auto-accepted, confirms auto-yes, prompts return default text when serving
- `requests` captures fetch/XHR calls (method, URL, status, timing) — first call installs hooks, subsequent calls drain the buffer
- `upload` sets file input programmatically via DataTransfer API — takes selector, base64 data, filename, mime_type

## Conventions

- No Co-Authored-By lines in commits
- Keep it minimalist — no unnecessary features or abstractions
- Test infrastructure uses `#ifdef SWIM_TEST` to compile out of release builds
