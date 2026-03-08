# Test Server API v2 — Design

**Goal:** Make swim's test server ergonomic enough for Claude to drive uninterrupted — named keys, wait-for-load, JS eval, and batch operations.

**Principle:** Every feature should be testable via the test server so Claude can iterate with screenshots and state inspection without human in the loop.

---

## 1. Named Key Mapping

Enhance existing `POST /key` to translate human-readable key names.

```
POST /key {"key": "Escape"}     → \x1b
POST /key {"key": "Enter"}      → \r
POST /key {"key": "Tab"}        → \t
POST /key {"key": "Backspace"}  → \x7f
POST /key {"key": "ArrowUp"}    → NSUpArrowFunctionKey
POST /key {"key": "ArrowDown"}  → NSDownArrowFunctionKey
POST /key {"key": "Space"}      → " "
POST /key {"key": "Ctrl-D"}     → \x04 with MOD_CTRL
POST /key {"key": "j"}          → unchanged (single chars pass through)
```

No new endpoint. Raw characters still work.

## 2. Wait for Page Load

```
POST /wait {"timeout": 5000}
```

Blocks until active tab's WKWebView finishes loading (`isLoading` becomes NO). Returns when loaded or timeout hit.

- Response: `{"ok": true, "loaded": true}` or `{"ok": true, "loaded": false}`
- Default timeout: 10000ms

## 3. JS Eval

```
POST /eval {"js": "document.title"}
```

Runs JS via `evaluateJavaScript:` on active webview, returns result.

- Response: `{"ok": true, "result": "Example Domain"}` or `{"ok": false, "error": "..."}`
- Pass `"json": true` to wrap in `JSON.stringify(...)` for objects/arrays

## 4. Batch Endpoint

```
POST /batch
[
  {"type": "key", "key": "Escape"},
  {"type": "wait", "timeout": 3000},
  {"type": "eval", "js": "document.title"},
  {"type": "screenshot"},
  {"type": "action", "action": "scroll-down", "count": 5},
  {"type": "command", "command": "open https://example.com"},
  {"type": "state"},
  {"type": "resize", "width": 800, "height": 600},
  {"type": "sleep", "ms": 500}
]
```

- Sequential execution, returns array of results in order
- Failed steps include error but don't short-circuit
- Screenshots in batch are base64-encoded (standalone `GET /screenshot` still returns raw PNG)
- `sleep` step for small delays between actions

Response:
```json
{
  "ok": true,
  "results": [
    {"ok": true, "consumed": true},
    {"ok": true, "loaded": true},
    {"ok": true, "result": "Example Domain"},
    {"ok": true, "content_type": "image/png", "base64": "iVBOR..."},
    {"ok": true},
    ...
  ]
}
```
