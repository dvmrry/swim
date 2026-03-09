# AI-Native Platform — Design Document

## Goal

Make swim the first browser built for both human and AI operators.
Phase 1 MVP: MCP server sidecar + content extraction.

## Architecture

Two deliverables:

1. **Promote `--test-server` to `--serve`** — remove `#ifdef SWIM_TEST`,
   clean up the API, ship in release binary.

2. **`swim-mcp`** — separate small binary. MCP clients spawn it, it
   translates MCP tool calls to HTTP requests against `swim --serve`.

```
┌─────────────────┐     MCP (stdio)     ┌──────────┐
│  Claude Code /  │ ◄────────────────► │ swim-mcp │
│  Any MCP Client │                     └────┬─────┘
└─────────────────┘                          │ HTTP
                                             ▼
                                     ┌──────────────┐
                                     │ swim --serve  │
                                     │    :9111      │
                                     └──────────────┘
```

### Why Sidecar (not built-in)

- Browser stays running regardless of MCP client lifecycle
- MCP complexity lives in a separate binary
- HTTP API is the stable contract — any future client can use it
- If MCP process crashes, browser is unaffected

### Future Path

Sidecar (B) → Built-in (C) when the MCP protocol surface is stable.
Never option A (client spawns browser) — the browser owns its lifecycle.

## MCP Tool Surface

Each tool maps 1:1 to an HTTP endpoint on `swim --serve`:

| MCP Tool | HTTP Endpoint | Description |
|----------|--------------|-------------|
| `navigate` | POST /command | `open <url>` |
| `screenshot` | GET /screenshot | PNG of current page |
| `extract` | GET /extract | Markdown content + metadata |
| `execute` | POST /command | Run any `:command` |
| `action` | POST /action | Trigger any keybinding action |
| `state` | GET /state | Mode, URL, tab list, title |
| `key` | POST /key | Send raw keypress |
| `click` | POST /click | Click element by CSS selector or text |

### Not in MVP (future)

- `fill_form` — needs DOM-level extraction (forms, fields, state)
- `select_tab` — achievable via `execute` with goto-tab for now
- Accessibility tree / DOM snapshot — Phase 2 extraction
- Interaction-level extraction (element positions, clickable regions)
- Single meta-tool (`swim` with `method` param) — simplifies MCP
  permission whitelist to one entry instead of per-tool. Trades
  discoverability for convenience. Revisit when tool surface stabilizes.

## Content Extraction (GET /extract)

Runs JS in the active tab. Reuses reader-mode content finder from
`focus.js` — already knows how to locate main article content with
site-specific handling (Reddit, etc). Returns content as markdown
instead of rendering an overlay.

### Response Format

```json
{
  "url": "https://example.com/article",
  "title": "Page Title",
  "content": "## Heading\n\nArticle body in markdown...",
  "links": [
    {"text": "About", "href": "/about"},
    {"text": "Pricing", "href": "/pricing"}
  ],
  "meta": {
    "description": "Page description",
    "og:image": "https://..."
  }
}
```

- `content` — markdown body from reader-mode extraction
- `links` — all visible `<a>` elements, gives AI navigation context
- `meta` — page-level metadata (description, OpenGraph)

### Decision Log

- Started with reader-mode markdown (fastest to build, reuses focus.js)
- Future: add DOM/interaction-level extraction as separate endpoint or
  parameter (e.g., `GET /extract?mode=dom`)
- Options considered:
  - (A) Text only — too lossy
  - (B) Markdown — good for reading, chosen for content body format
  - (C) Structured JSON — full envelope format chosen
  - (D) Reader mode + metadata — chosen as extraction strategy

## Click Element (POST /click)

Direct JS injection: `document.querySelector(selector).click()`.
AI passes a CSS selector or text content match.

### Why Not Hints

The hint system is for humans (visual labels, keyboard selection).
AI doesn't need the overlay — it knows what to click from
extract/screenshot data. Direct JS is cleaner, no visual side effects.

## Build & Files

### Changes

- `test_server.m` → rename to `serve.m`, remove `#ifdef SWIM_TEST`
- `test_server.h` → rename to `serve.h`
- New: `swim-mcp.c` — standalone binary, pure C, MCP on stdio
- New: `js/extract.js` — content extraction (reader-mode to markdown)
- Makefile: `swim` always includes serve, new `swim-mcp` target

### Binary Sizes (estimated)

- `swim` grows ~5-10KB (serve code no longer conditional)
- `swim-mcp` ~20-30KB standalone binary

### Usage

```bash
# Start browser with API
swim --serve 9111

# Claude Code MCP config (~/.claude/mcp.json)
{
  "swim": {
    "command": "./swim-mcp",
    "args": ["--port", "9111"]
  }
}
```

### Testing

Existing test infrastructure works — same API, same endpoints.
New endpoints (extract, click) tested the same way. The test binary
distinction goes away since serve is always compiled in.

## Architectural Rules (from ROADMAP.md)

1. Core never imports platform headers
2. Webview is opaque (`void *webview`)
3. Actions and commands are the API boundary
4. The wrapper is thin

`swim-mcp` follows rule 1 strictly — pure C, no platform deps.
The serve/HTTP layer stays in ObjC (needs webview access for screenshots).
Extract JS runs in the webview, returns data through the HTTP API.

---

*Approved: 2026-03-09*
