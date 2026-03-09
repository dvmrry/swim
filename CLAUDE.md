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
swim --serve 9111    # start with HTTP API on port 9111
```

Endpoints: /health, /state, /screenshot, /extract, /click, /action, /command, /key, /eval, /wait, /batch, /resize

## MCP Integration

```
swim-mcp --port 9111  # MCP sidecar (add to Claude Code mcp.json)
```

Tools: navigate, screenshot, extract, execute, action, state, click, key

## Conventions

- No Co-Authored-By lines in commits
- Keep it minimalist — no unnecessary features or abstractions
- Test infrastructure uses `#ifdef SWIM_TEST` to compile out of release builds
