# AI Companion — Design Document

## Goal

Make Claude a real-time browser companion — always aware, always accessible.
Two surfaces: an embedded sidebar for quick contextual help, and Claude Code
via MCP for heavy automation. Both powered by the same event stream and API.

## Architecture

```
                ┌─────────────────────────────────────┐
                │            swim browser             │
                │  ┌──────────────┬──────────────────┐ │
                │  │              │  AI Sidebar      │ │
                │  │  page        │  (WKWebView)     │ │
                │  │  content     │  routes through  │ │
                │  │              │  MCP connection  │ │
                │  │              │                  │ │
                │  └──────────────┴──────────────────┘ │
                │                                     │
                │  /events (SSE) ──────────┐          │
                │  /action, /fill, etc.    │          │
                └──────────────────────────┼──────────┘
                                           │
                  ┌────────────────────────┐│  ┌──────────────┐
                  │  swim-mcp (sidecar)    ││  │  curl / any  │
                  │  MCP stdio ↔ HTTP/sock │◄┘  │  HTTP client │
                  └────────┬───────────────┘    └──────────────┘
                           │
                  ┌────────▼───────────────┐
                  │  Claude Code (terminal) │
                  │  (Pro/Max plan)         │
                  └────────────────────────┘
```

Four deliverables, built in order:

1. **`/events` SSE endpoint** — foundation for everything
2. **Sidebar UI** — embedded chat panel with Claude Code-inspired design
3. **MCP event forwarding** — Claude Code sees browser activity
4. **Workflow learning** — teach repetitive tasks by demonstration

---

## 1. Event Stream (`/events` SSE)

### What it is

Server-Sent Events endpoint. swim pushes browser events as they happen.
Any number of clients can subscribe. No polling.

### Event types

```
event: navigation
data: {"url":"https://...","title":"Page Title"}

event: load
data: {"url":"https://...","status":"complete"}

event: error
data: {"type":"console","level":"error","message":"..."}

event: form
data: {"action":"fill","selector":"#email","value":"user@..."}

event: action
data: {"name":"scroll-down","source":"user"}

event: click
data: {"selector":"button.submit","text":"Submit"}

event: tab
data: {"action":"switch","index":2,"url":"...","title":"..."}
```

### Filtering

Query params control what events stream. Keeps sidebar cheap,
lets Claude Code go deep when needed.

```
GET /events                          # everything
GET /events?types=navigation,load    # nav only (sidebar default)
GET /events?types=form,click,action  # interaction tracking (workflow learning)
```

### Implementation

~100 LOC in serve.m. Maintain a linked list of SSE client file descriptors.
When `handle_action` fires, broadcast to all connected clients. Events are
fire-and-forget — if a client disconnects, remove from list.

Each event source in main.m/serve.m calls `events_broadcast(type, json_data)`.
The broadcast function writes `event: <type>\ndata: <json>\n\n` to each fd.

### Connection management

- Clients send `Accept: text/event-stream`
- Server responds with `Content-Type: text/event-stream`, `Cache-Control: no-cache`
- Keep-alive via `: keepalive\n\n` every 30s
- Client disconnect detected on write failure → remove from list
- Max 10 concurrent SSE clients (prevent fd exhaustion)

---

## 2. Sidebar UI

### Design: Claude Code-inspired

The sidebar takes visual cues from Claude Code's terminal aesthetic:

- **Dark background** matching the swim theme (`bg` color)
- **Monospace font** for all text (same family as status bar)
- **Minimal chrome** — no buttons, borders, or decorations
- **Color-coded messages:**
  - User input: theme `fg` (bright)
  - AI response: theme `fg_dim` or slightly brighter
  - System/status: theme `accent`
  - Thinking indicator: theme `fg_dim` with subtle pulse
- **Markdown rendering** in responses (headers, code blocks, lists, links)
- **Input at bottom** — single-line text field, Enter to send
  - Shift+Enter for multi-line (or auto-expand)
  - Up arrow recalls previous prompts
- **Auto-scroll** to latest message, scroll lock on manual scroll-up

The sidebar is a local HTML/CSS/JS page loaded in a WKWebView. No external
dependencies, no frameworks. The HTML/CSS/JS lives as a string constant in
the source (like extract_js.inc), themed dynamically with swim's current
theme colors injected at load time.

### Layout

```
┌─────────────────────┬──────────────┐
│                     │  ┌ messages ┐ │
│                     │  │ user: .. │ │
│  page content       │  │ ai: ...  │ │
│  (existing webview) │  │ user: .. │ │
│                     │  │ ai: ...  │ │
│                     │  └──────────┘ │
│                     │  ┌ input ───┐ │
│                     │  │ > _      │ │
│                     │  └──────────┘ │
└─────────────────────┴──────────────┘
```

Width: 30% of window, min 280px, max 400px. Collapsible to 0 via
zero-width NSLayoutConstraint (same pattern as tab bar/status bar).

### Toggle

- `ga` in normal mode — toggle sidebar open/closed
- `:ai` — open sidebar (if closed) and focus input
- `:ai close` — collapse sidebar
- `:ai <prompt>` — open sidebar and submit prompt immediately
- `:ai+ <prompt>` — same but force Sonnet model
- Escape in sidebar input — return focus to page (normal mode)

### Collapse behavior

- Sidebar webview stays alive when collapsed (chat history preserved)
- Collapse is session-only, not persisted
- Fresh launch respects config: `sidebar = "always"|"never"|"auto"`
- `auto` = start collapsed, open on `:ai`

### Routing: MCP-first (Pro-compatible)

The sidebar does NOT call the Claude API directly. Instead, it routes
prompts through the existing MCP connection to Claude Code. This means:

- **No API key required** — covered by Pro/Max subscription
- **No extra cost** — same usage bucket as Claude Code
- **Claude Code must be running** — sidebar is a UI for MCP, not standalone

Flow: sidebar JS → `window.webkit.messageHandlers.swim` → swim process →
swim-mcp → Claude Code session → response back through same chain.

If no MCP session is active, sidebar shows "Connect Claude Code to enable AI"
with instructions. Future: optional direct API fallback for users with API keys.

### Model routing

`:ai` requests Haiku-class responses (compact context, short answers).
`:ai+` requests Sonnet-class responses (full context, deeper analysis).
Model selection is communicated as a hint in the MCP tool call — Claude Code
routes to the appropriate model based on the request complexity.

### System context

The sidebar injects page context before each prompt by calling swim's
own `/extract` and `/interact` endpoints locally:

```
Current page:
- URL: {url}
- Title: {title}
- Headings: {headings from layout extraction}
- Form fields: {from /interact}
```

Context is tiered:
- **Compact (default):** headings + form fields + fingerprint (~300 tokens)
- **Full (on demand):** complete extract with content (~2-5K tokens)

Compact context is sent with every prompt. Full extract only when the
user asks for summarization or deep analysis.

### UI implementation

The sidebar is a second WKWebView managed by SwimUI. New ui.h functions:

```c
void ui_show_sidebar(SwimUI *ui);
void ui_hide_sidebar(SwimUI *ui);
void ui_toggle_sidebar(SwimUI *ui);
bool ui_sidebar_visible(SwimUI *ui);
void ui_sidebar_submit(SwimUI *ui, const char *prompt, bool force_sonnet);
```

The sidebar webview loads a local HTML string (no file:// URL needed).
Communication between swim and sidebar via `WKScriptMessageHandler`:
- swim → sidebar: `evaluateJavaScript` to inject page context, theme colors
- sidebar → swim: `window.webkit.messageHandlers.swim.postMessage(...)` for
  actions the AI suggests (navigate, click, fill)

---

## 3. MCP Event Forwarding

### New MCP method: `subscribe`

```json
{"method": "subscribe", "params": {"types": ["navigation", "load", "error"]}}
```

swim-mcp connects to `/events?types=...` SSE and forwards events as MCP
notifications. Claude Code sees browser activity without polling.

```json
{"jsonrpc": "2.0", "method": "notifications/browser_event",
 "params": {"type": "navigation", "data": {"url": "...", "title": "..."}}}
```

### Unsubscribe

```json
{"method": "unsubscribe"}
```

Closes the SSE connection. swim-mcp stops forwarding.

### Implementation

swim-mcp spawns a thread that reads from the SSE connection and writes
MCP notifications to stdout. Thread-safe with a mutex on the stdout fd.

---

## 4. Workflow Learning

### Concept

Claude watches the user perform a task via the event stream, understands
the *intent* (not just the clicks), and saves a workflow description that
can be replayed with adaptation.

### Recording

```
:ai watch                    → Claude starts observing events
  (user performs task)
:ai done                     → Claude summarizes, offers to save
:ai save expense_report      → workflow saved
```

During recording, sidebar subscribes to `/events?types=form,click,action,navigation`
and accumulates events. On `:ai done`, Claude receives the full event log and
generates a workflow.

### Workflow format

Workflows live in `~/.config/swim/workflows/<name>.md` as natural language
descriptions with selector hints. Markdown, not JSON — Claude reads and
writes these naturally.

```markdown
# expense_report

## Trigger
User says "expense report" or navigates to expenses.internal.corp/*

## Goal
Submit a weekly expense report with date, amount, category, description.

## Parameters
- date: expense date (default: today)
- amount: dollar amount
- category: one of Travel, Meals, Equipment, Other
- description: free text

## Steps
1. Navigate to expenses.internal.corp/new
2. Wait for form to load (selector: #expense-form)
3. Fill date field (hint: #date, input[name="date"])
4. Fill amount (hint: #amount, input[name="amount"])
5. Select category from dropdown (hint: #category, select[name="category"])
6. Fill description (hint: #description, textarea[name="desc"])
7. Click submit (hint: .btn-primary, button[type="submit"])
8. Wait for confirmation (hint: .alert-success, .toast, .confirmation)

## Notes
- Category dropdown sometimes has "Software" option on tech team pages
- Amount field validates on blur — fill before date to avoid focus issues
```

### Replay

```
:ai run expense_report date=2026-03-10 amount=42.50 category=Meals
```

Claude reads the workflow file, fetches current page state via `/extract`
and `/interact`, then executes steps through the existing API (fill, click,
wait_for). Haiku is sufficient for replay — it's following a recipe, not
creating one.

If a step fails (selector not found, page looks different), Claude adapts
using the intent description and current page state. If it can't recover,
it asks the user in the sidebar.

### Multiple recordings

Running `:ai watch` on the "same" task again enriches the workflow. Claude
sees variations: "sometimes there's a category field, sometimes not" and
updates the workflow description. The workflow evolves from a single example
into a robust pattern.

### Storage

```
~/.config/swim/workflows/
├── expense_report.md
├── weekly_schedule.md
└── jira_ticket.md
```

Plain markdown files. Editable by hand. Claude reads them with the file
system, no special parser needed.

---

## Usage Impact (Pro/Max Plans)

The sidebar is negligible against normal Claude Code usage. A typical
Claude Code dev interaction (read files, write code, run tests) costs
10K-50K tokens. Sidebar interactions are a fraction of that:

| Action | ~Tokens | vs. one CC interaction |
|--------|---------|------------------------|
| "What is this page?" | 800 | 1/30th |
| Fill a form | 1,500 | 1/15th |
| Workflow replay | 1,500 | 1/15th |
| Summarize small page | 2,500 | 1/10th |
| Summarize medium page | 4,000 | 1/8th |
| Summarize large page | 12,000 | 1/3rd |

### Research session example (2 hours)

- 30 page summaries (mixed sizes): ~100K tokens
- 20 quick questions: ~16K tokens
- 5 comparisons: ~25K tokens
- **Total: ~140K tokens ≈ 4-5 Claude Code exchanges**

For context, a single "implement this feature" coding prompt can burn
100K+ tokens. The sidebar is a rounding error — casual enough to use
like Ctrl+F without worrying about allowance.

### Why it stays cheap

- Compact context by default (~300 tokens, not full page extract)
- Ephemeral per page — no accumulating conversation history
- User-initiated only — sidebar never auto-analyzes
- Haiku-class default — smaller model, less usage per interaction

## Config

```toml
[ai]
enabled = true
sidebar = "auto"                 # "always", "never", "auto"
```

- `enabled = false` means no sidebar, no event stream overhead
- Profiles can override `sidebar` visibility
- No API key needed when routing through MCP/Claude Code
- Future: optional `api_key` field for standalone sidebar (no Claude Code)
- `:set ai.sidebar always` works at runtime

---

## Implementation Order

### Phase 2a: Event Stream
- `/events` SSE endpoint in serve.m
- Event broadcasting from handle_action, navigation delegates
- Basic event types: navigation, load, error, tab

### Phase 2b: Sidebar
- WKWebView split pane in ui.m
- HTML/CSS/JS chat interface (Claude Code aesthetic)
- Claude API integration (Haiku default)
- Page context injection from /extract, /interact
- `:ai` command family
- `ga` keybinding

### Phase 2c: MCP Events
- `subscribe`/`unsubscribe` MCP methods in swim-mcp
- SSE → MCP notification forwarding
- Thread management in sidecar

### Phase 2d: Workflow Learning
- `:ai watch`/`:ai done`/`:ai save` commands
- Event accumulation during recording
- Workflow file generation (markdown)
- `:ai run` replay with adaptation

---

## Non-Goals

- Running Claude locally (API only — no llama.cpp, no GGUF)
- Voice interface
- Multi-model routing beyond Haiku/Sonnet
- Autonomous browsing without user present
- Replacing Claude Code — the terminal stays for heavy work

## Design Decisions

1. **Sidebar is HTML in WKWebView, not native Cocoa** — faster to iterate,
   naturally supports markdown rendering, theme injection via CSS variables.
   The chat UI is a web page, which is what swim knows how to host.

2. **MCP-first routing, not direct API** — sidebar routes through Claude
   Code's MCP connection. No API key needed, covered by Pro/Max plan.
   Negligible usage impact (~1/10th of a coding interaction per query).
   Optional direct API fallback for power users without Claude Code.

3. **Workflows as markdown, not JSON** — Claude reads and writes markdown
   naturally. Humans can edit them. No parser to maintain. The "schema" is
   the section headers (Trigger, Goal, Parameters, Steps, Notes).

4. **Haiku default, Sonnet on demand** — 90% of sidebar interactions are
   quick contextual questions. Haiku handles these at ~1/10 the cost.
   User explicitly opts into Sonnet when depth is needed.

5. **Event stream as foundation** — both sidebar and MCP consume the same
   stream. Adding a third consumer (workflow recorder, debug logger,
   analytics) requires zero new infrastructure.

---

*Approved: pending*
