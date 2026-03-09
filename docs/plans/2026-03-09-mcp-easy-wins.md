# MCP Easy Wins Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the gaps between swim MCP and Playwright MCP with 5 low-effort, high-value features.

**Architecture:** All features follow the existing pattern: `do_*` function in serve.m with JS injection → thin HTTP handler → MCP method in swim-mcp.c. The `hover` and `console` features are pure JS. The `navigate_back` is just a new explicit method. PDF uses WKWebView's native `createPDF`. The eval fix is a swim-mcp.c-only change to pass raw JS through cleanly.

**Tech Stack:** C (swim-mcp.c), Objective-C (serve.m), WebKit APIs

---

### Task 1: Add `/hover` endpoint

Dispatch mouseover/mouseenter events on an element by CSS selector. Same pattern as `/click` but with hover events instead of `.click()`.

**Files:**
- Modify: `serve.m` — add `do_hover` function, `handle_hover` wrapper, route, batch entry
- Modify: `swim-mcp.c` — add `hover` to method enum, tool description, handler
- Modify: `CLAUDE.md` — update endpoint and tool lists

**Step 1: Add `do_hover` in serve.m**

Add after `do_click`, before `do_sleep_step`. Same dispatch_sync/evaluateJavaScript pattern as `do_click`:

```objc
static NSDictionary *do_hover(NSDictionary *json, ServeContext *ctx) {
    NSString *selector = json[@"selector"];
    if (!selector) return @{@"ok": @NO, @"error": @"missing selector"};

    NSString *escaped = [selector stringByReplacingOccurrencesOfString:@"\\"
                                                           withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'"
                                                 withString:@"\\'"];

    NSString *js = [NSString stringWithFormat:
        @"(function(){"
        "var el=document.querySelector('%@');"
        "if(!el)return JSON.stringify({ok:false,error:'not found'});"
        "el.dispatchEvent(new MouseEvent('mouseenter',{bubbles:true}));"
        "el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));"
        "return JSON.stringify({ok:true})"
        "})()", escaped];

    // ... standard evaluateJavaScript wrapper (copy from do_click) ...
}
```

**Step 2: Add handler, route, batch**

- `handle_hover`: same pattern as `handle_click` (parse body JSON, call `do_hover`)
- Route: `POST /hover` in the `strcmp` chain
- Batch: add `else if ([type isEqualToString:@"hover"]) { result = do_hover(step, ctx); }`

**Step 3: Add MCP handler in swim-mcp.c**

Add `"hover"` to the method enum in `kToolsList`. Add handler:

```c
if (strcmp(name, "hover") == 0) {
    char *selector = json_get_string(arguments, "selector");
    if (!selector) return strdup("{\"error\":\"missing selector\"}");
    char *escaped = json_escape(selector);
    char body[4096];
    snprintf(body, sizeof(body), "{\"selector\":\"%s\"}", escaped);
    free(escaped); free(selector);
    char *resp = http_post("/hover", body);
    return resp ? resp : strdup("{\"error\":\"connection failed\"}");
}
```

**Step 4: Build and test**

```bash
make
# Restart swim, navigate to a page with hover effects
curl -s -X POST http://localhost:9111/hover -H 'Content-Type: application/json' \
  -d '{"selector":"a"}'
# Expect: {"ok":true}
curl -s -X POST http://localhost:9111/hover -d '{"selector":"#nope"}'
# Expect: {"ok":false,"error":"not found"}
```

**Step 5: Commit**

```
Add /hover endpoint for mouseover events
```

---

### Task 2: Add `/console` endpoint (read console messages)

Inject a WKUserScript that captures `console.log/warn/error` into a buffer. The `/console` endpoint returns and clears the buffer.

**Files:**
- Modify: `serve.m` — add console buffer, inject capture script in webview creation, add `do_console`/`handle_console`
- Modify: `ui.m` — add console capture WKUserScript injection
- Modify: `ui.h` — add `ui_get_console_messages` and `ui_clear_console_messages` declarations
- Modify: `swim-mcp.c` — add `console` method
- Modify: `CLAUDE.md`

**Step 1: Add console capture via eval**

Rather than modifying the webview creation pipeline, use a simpler approach — inject a capture script on demand and read the buffer:

```objc
static NSDictionary *do_console(NSDictionary *json, ServeContext *ctx) {
    // Inject capture script if not already present, then read buffer
    NSString *js =
        @"(function(){"
        "if(!window.__swim_console){"
        "  window.__swim_console=[];"
        "  var orig={log:console.log,warn:console.warn,error:console.error,info:console.info};"
        "  ['log','warn','error','info'].forEach(function(level){"
        "    console[level]=function(){"
        "      var args=[].slice.call(arguments).map(function(a){"
        "        try{return typeof a==='object'?JSON.stringify(a):String(a)}"
        "        catch(e){return String(a)}"
        "      });"
        "      window.__swim_console.push({level:level,text:args.join(' '),ts:Date.now()});"
        "      if(window.__swim_console.length>200)window.__swim_console.shift();"
        "      orig[level].apply(console,arguments)"
        "    }"
        "  })"
        "}"
        "var msgs=window.__swim_console.splice(0);"
        "return JSON.stringify({ok:true,messages:msgs,count:msgs.length})"
        "})()";

    // ... standard evaluateJavaScript wrapper ...
}
```

The `clear` param (optional, default true) controls whether messages are consumed or peeked. The `splice(0)` approach consumes by default.

**Step 2: Add handler, route, batch, MCP**

Same pattern as other endpoints:
- Route: `GET /console`
- Batch type: `"console"`
- MCP method: `"console"` → `http_get("/console")`

**Step 3: Build and test**

```bash
make
# Navigate to any page, then check console
curl -s http://localhost:9111/console
# Expect: {"ok":true,"messages":[],"count":0}
# Trigger a console.log via eval, then read
curl -s -X POST http://localhost:9111/eval -d '{"js":"console.log(\"hello from swim\"); \"ok\""}'
curl -s http://localhost:9111/console
# Expect: {"ok":true,"messages":[{"level":"log","text":"hello from swim","ts":...}],"count":1}
```

**Step 4: Commit**

```
Add /console endpoint for reading browser console messages
```

---

### Task 3: Add `navigate_back` and `navigate_forward` MCP methods

These already work via `action("back")` and `action("forward")`, but Playwright exposes them explicitly. Add them as first-class MCP methods that map to the existing actions — pure swim-mcp.c change, zero serve.m work.

**Files:**
- Modify: `swim-mcp.c` — add methods to enum, add handlers

**Step 1: Add handlers in swim-mcp.c**

```c
if (strcmp(name, "navigate_back") == 0) {
    char *resp = http_post("/action", "{\"action\":\"back\"}");
    return resp ? resp : strdup("{\"error\":\"connection failed\"}");
}

if (strcmp(name, "navigate_forward") == 0) {
    char *resp = http_post("/action", "{\"action\":\"forward\"}");
    return resp ? resp : strdup("{\"error\":\"connection failed\"}");
}
```

Add `"navigate_back"` and `"navigate_forward"` to the method enum and description in `kToolsList`.

**Step 2: Build and test**

```bash
make swim-mcp
pkill -f swim-mcp  # let Claude Code restart it
# Test via MCP: navigate somewhere, then navigate_back
```

**Step 3: Commit**

```
Add navigate_back and navigate_forward as explicit MCP methods
```

---

### Task 4: Add `/pdf` endpoint

Use WKWebView's `createPDFWithConfiguration` to save the current page as PDF. Return base64-encoded PDF data.

**Files:**
- Modify: `serve.m` — add `do_pdf`, `handle_pdf`, route
- Modify: `swim-mcp.c` — add `pdf` method (returns base64 like screenshot)
- Modify: `CLAUDE.md`

**Step 1: Add `do_pdf` in serve.m**

```objc
static void handle_pdf(int fd, ServeContext *ctx) {
    __block NSData *pdfData = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) return;

        __block BOOL done = NO;
        WKPDFConfiguration *config = [[WKPDFConfiguration alloc] init];

        [wv createPDFWithConfiguration:config completionHandler:^(NSData *data, NSError *error) {
            if (!error) pdfData = data;
            done = YES;
        }];

        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                 beforeDate:timeout]) {
            if ([timeout timeIntervalSinceNow] <= 0) break;
        }
    });

    if (pdfData) {
        // Send raw PDF with application/pdf content type
        char header[256];
        int hlen = snprintf(header, sizeof(header),
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/pdf\r\n"
            "Content-Length: %lu\r\n\r\n",
            (unsigned long)pdfData.length);
        write(fd, header, hlen);
        write(fd, pdfData.bytes, pdfData.length);
    } else {
        send_json(fd, 500, "{\"error\":\"pdf generation failed\"}");
    }
}
```

Route: `GET /pdf`

**Step 2: MCP handler in swim-mcp.c**

Same pattern as screenshot — get raw bytes, base64 encode, return as content:

```c
if (strcmp(name, "pdf") == 0) {
    int len = 0;
    char *raw = http_get_raw("/pdf", &len);
    if (!raw || len <= 0) { free(raw); return strdup("{\"error\":\"pdf failed\"}"); }
    char *b64 = base64_encode((unsigned char *)raw, len);
    free(raw);
    int resp_size = (int)strlen(b64) + 256;
    char *resp = malloc(resp_size);
    snprintf(resp, resp_size,
        "{\"type\":\"resource\",\"data\":\"%s\",\"mimeType\":\"application/pdf\"}", b64);
    free(b64);
    return resp;
}
```

**Step 3: Build and test**

```bash
make
curl -s http://localhost:9111/pdf -o /tmp/swim-test.pdf && file /tmp/swim-test.pdf
# Expect: /tmp/swim-test.pdf: PDF document
```

**Step 4: Commit**

```
Add /pdf endpoint for page-to-PDF export
```

---

### Task 5: Add `eval` as proper MCP method

Currently there's no way to run arbitrary JS through the MCP tool without falling back to curl. The `execute` method runs `:commands`, not JS. Add `eval` as a first-class MCP method with a `js` parameter.

**Files:**
- Modify: `swim-mcp.c` — add `eval` method, `js` parameter to schema

**Step 1: Add to kToolsList**

Add `"eval"` to method enum. Add `"js"` parameter:
```
"\"js\":{\"type\":\"string\",\"description\":\"JavaScript to evaluate in page (eval)\"},"
```

Update description to include `eval (js)`.

**Step 2: Add handler**

```c
if (strcmp(name, "eval") == 0) {
    char *js = json_get_string(arguments, "js");
    if (!js) return strdup("{\"error\":\"missing js\"}");
    char *escaped = json_escape(js);
    int bsize = (int)strlen(escaped) + 64;
    char *body = malloc(bsize);
    snprintf(body, bsize, "{\"js\":\"%s\"}", escaped);
    free(escaped); free(js);
    char *resp = http_post("/eval", body);
    free(body);
    return resp ? resp : strdup("{\"error\":\"connection failed\"}");
}
```

**Step 3: Build and test**

```bash
make swim-mcp
pkill -f swim-mcp
# Test via MCP tool: swim method=eval js="document.title"
# Expect: {"ok":true,"result":"...page title..."}
```

**Step 4: Commit**

```
Add eval as first-class MCP method for arbitrary JS execution
```

---

### Task 6: Update docs and roadmap

**Files:**
- Modify: `CLAUDE.md` — update endpoint and tool lists
- Modify: `docs/ROADMAP.md` — add sore spots to maturity roadmap

**Step 1: Update CLAUDE.md**

Add `/hover`, `/console`, `/pdf` to endpoints list. Add `hover`, `console`, `navigate_back`, `navigate_forward`, `pdf`, `eval` to MCP tools list.

**Step 2: Update ROADMAP.md maturity section**

Add after existing iframe section:

```markdown
### File Upload
WKWebView file input handling. Requires native file picker bypass —
set file input value programmatically or use `WKOpenPanelParameters` delegate.

### Network Request Inspection
WKWebView doesn't expose network layer. Options: custom URL protocol handler
(`WKURLSchemeHandler`), or inject `fetch`/`XMLHttpRequest` wrapper JS.
Highest complexity of remaining features.

### Drag and Drop
Mouse event sequence: mousedown → mousemove → mouseup. Needs coordinate
calculation from element bounding rects. Medium effort.

### JS-Heavy Page Extraction
`/extract` returns empty on SPAs that render via JS (React, Vue, GitHub).
Options: wait for idle, use innerText instead of readability heuristics,
or fall back to accessibility tree approach.
```

**Step 3: Commit**

```
Update docs with new MCP methods and maturity roadmap items
```
