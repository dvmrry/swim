# AI-Native Platform Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship swim's MCP server sidecar so AI tools can browse through swim.

**Architecture:** Promote the test server to a release `--serve` flag. Add /extract and /click endpoints. Build `swim-mcp` as a separate pure-C binary that bridges MCP stdio ↔ swim HTTP API.

**Tech Stack:** C/Objective-C, POSIX sockets, MCP JSON-RPC over stdio

**Design doc:** `docs/plans/2026-03-09-ai-native-platform-design.md`

---

### Task 1: Promote test_server to serve

Remove `#ifdef SWIM_TEST` guards, rename files and symbols, make `--serve` available in the release binary.

**Files:**
- Rename: `test_server.h` → `serve.h`
- Rename: `test_server.m` → `serve.m`
- Modify: `ui.h` (move screenshot/webview functions out of `#ifdef`)
- Modify: `ui.m` (remove `#ifdef SWIM_TEST` around screenshot/utility functions)
- Modify: `main.m` (replace `--test-server` with `--serve`, remove `#ifdef` guards)
- Modify: `Makefile` (update source lists, merge build targets)

**Step 1: Rename files**

```bash
git mv test_server.h serve.h
git mv test_server.m serve.m
```

**Step 2: Update serve.h — remove `#ifdef`, rename symbols**

Replace entire contents of `serve.h`:

```c
#ifndef SWIM_SERVE_H
#define SWIM_SERVE_H

#include "ui.h"
#include "browser.h"
#include "input.h"
#include "commands.h"

typedef struct ServeContext {
    SwimUI *ui;
    Browser *browser;
    ModeManager *mode;
    CommandRegistry *commands;
    void (*handle_action)(const char *action, void *ctx);
    void *action_ctx;
} ServeContext;

// Starts HTTP server on given port in a background thread.
// ctx must remain valid for the lifetime of the server.
void serve_start(int port, ServeContext *ctx);

#endif
```

**Step 3: Update serve.m — remove `#ifdef`, rename symbols**

- Remove `#ifdef SWIM_TEST` on line 1 and `#endif` on last line
- Replace all `TestContext` → `ServeContext`
- Replace `test_server_start` → `serve_start`
- Replace `#include "test_server.h"` → `#include "serve.h"`
- Change startup log from `"Test server listening on port %d\n"` → `"swim: serving on port %d\n"`

**Step 4: Update ui.h — move functions out of `#ifdef`**

Move these declarations out of the `#ifdef SWIM_TEST` block so they're always available:

```c
// Capture active tab as PNG. Returns NSData* (cast to void*).
void *ui_screenshot(SwimUI *ui);
void *ui_get_window(SwimUI *ui);
bool ui_is_loading(SwimUI *ui);
void *ui_get_active_webview(SwimUI *ui);
```

Remove the `#ifdef SWIM_TEST` / `#endif` wrapping these declarations. Keep them at the end of the file, just unwrapped.

**Step 5: Update ui.m — remove `#ifdef SWIM_TEST` around functions**

Remove the `#ifdef SWIM_TEST` on the line before `ui_screenshot` and the `#endif` at the end of the file. The functions (`ui_screenshot`, `ui_get_window`, `ui_is_loading`, `ui_get_active_webview`) stay exactly as they are, just no longer conditional.

**Step 6: Update main.m — replace `--test-server` with `--serve`**

Replace the include:
```c
// Old:
#ifdef SWIM_TEST
#include "test_server.h"
#endif

// New:
#include "serve.h"
```

Replace the CLI argument parsing (remove `#ifdef` guards):
```c
// Old:
#ifdef SWIM_TEST
    int test_port = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test-server") == 0 && i + 1 < argc) {
            test_port = atoi(argv[++i]);
        }
    }
#endif

// New:
    int serve_port = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--serve") == 0 && i + 1 < argc) {
            serve_port = atoi(argv[++i]);
        }
    }
```

Replace the server startup block (remove `#ifdef` guards):
```c
// Old:
#ifdef SWIM_TEST
        if (test_port > 0) {
            NSWindow *test_window = (__bridge NSWindow *)ui_get_window(app.ui);
            [test_window setFrame:NSMakeRect(-2000, -2000, 1280, 800) display:YES animate:NO];
            static TestContext test_ctx;
            test_ctx = (TestContext){ ... };
            test_server_start(test_port, &test_ctx);
        }
#endif

// New:
        if (serve_port > 0) {
            static ServeContext serve_ctx;
            serve_ctx = (ServeContext){
                .ui = app.ui,
                .browser = &app.browser,
                .mode = &app.mode,
                .commands = &app.commands,
                .handle_action = handle_action,
                .action_ctx = &app,
            };
            serve_start(serve_port, &serve_ctx);
        }
```

Note: Remove the fixed window geometry / offscreen positioning — that was test-specific. The serve mode uses the normal window.

Also update the CLI arg skip in the URL loop:
```c
// Old:
#ifdef SWIM_TEST
                    if (strcmp(argv[i], "--test-server") == 0 && i + 1 < argc) i++;
#endif

// New:
                    if (strcmp(argv[i], "--serve") == 0 && i + 1 < argc) i++;
```

**Step 7: Update Makefile**

```makefile
CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra -Wpedantic -std=c17
FRAMEWORKS = -framework Cocoa -framework WebKit -framework QuartzCore -framework Network

SRC_C = browser.c input.c commands.c storage.c config.c userscript.c theme.c focus.c
SRC_M = main.m ui.m serve.m
SRC = $(SRC_C) $(SRC_M)
HEADERS = browser.h input.h commands.h ui.h storage.h config.h userscript.h theme.h focus.h serve.h

swim: $(SRC) $(HEADERS) focus_js.inc Info.plist
	$(CC) $(CFLAGS) $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist $(SRC) -o swim

# Convert focus.js to a C string literal for embedding
focus_js.inc: js/focus.js
	@echo "Generating focus_js.inc"
	@sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$$/\\n"/' js/focus.js > focus_js.inc

clean:
	rm -f swim swim-mcp focus_js.inc

.PHONY: clean
```

**Step 8: Build and verify**

```bash
make clean && make
```

Expected: Clean build, no errors. The `swim` binary now always includes the serve code.

**Step 9: Smoke test**

```bash
# Terminal 1: start swim with serve
./swim --serve 9111 https://example.com

# Terminal 2: test endpoints
curl -s http://localhost:9111/health
# Expected: {"ok":true}

curl -s http://localhost:9111/state | python3 -m json.tool
# Expected: JSON with mode, url, tabs, etc.

curl -s http://localhost:9111/screenshot -o /tmp/test.png && open /tmp/test.png
# Expected: PNG screenshot of the browser
```

**Step 10: Commit**

```bash
git add serve.h serve.m ui.h ui.m main.m Makefile
git commit -m "Promote test server to --serve, always compiled in"
```

---

### Task 2: Add /extract endpoint

Content extraction: runs JS in the active tab to pull reader-mode content, returns JSON with markdown body, links, and metadata.

**Files:**
- Create: `js/extract.js` — extraction script
- Create: `extract_js.inc` — auto-generated C string (like focus_js.inc)
- Modify: `serve.m` — add do_extract, handle_extract, wire route
- Modify: `Makefile` — add extract_js.inc generation

**Step 1: Create js/extract.js**

```javascript
(function(){
  // Get page metadata
  var meta = {};
  var metaTags = document.querySelectorAll('meta[name], meta[property]');
  for (var i = 0; i < metaTags.length; i++) {
    var name = metaTags[i].getAttribute('name') || metaTags[i].getAttribute('property');
    var content = metaTags[i].getAttribute('content');
    if (name && content) meta[name] = content;
  }

  // Find main content — reuse focus.js strategy
  var article = null;
  var host = location.hostname;

  // Site-specific extraction
  if (host === 'old.reddit.com') {
    article = document.querySelector('.sitetable.nestedlisting') ||
              document.querySelector('#siteTable');
  } else if (host.includes('reddit.com')) {
    article = document.querySelector('[data-testid="post-container"]') ||
              document.querySelector('.Post');
  } else if (host.includes('github.com')) {
    article = document.querySelector('.markdown-body') ||
              document.querySelector('.repository-content');
  }

  // Generic extraction
  if (!article) {
    article = document.querySelector('article') ||
              document.querySelector('[role="main"]') ||
              document.querySelector('main') ||
              document.querySelector('.post-content') ||
              document.querySelector('.article-content') ||
              document.querySelector('.entry-content');
  }

  var source = article || document.body;

  // Convert to markdown-ish text
  function toMarkdown(el) {
    var out = '';
    var children = el.childNodes;
    for (var i = 0; i < children.length; i++) {
      var node = children[i];
      if (node.nodeType === 3) {
        // Text node
        out += node.textContent;
      } else if (node.nodeType === 1) {
        var tag = node.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' ||
            tag === 'NAV' || tag === 'FOOTER' || tag === 'HEADER') continue;
        if (tag === 'H1') out += '\n# ' + node.textContent.trim() + '\n\n';
        else if (tag === 'H2') out += '\n## ' + node.textContent.trim() + '\n\n';
        else if (tag === 'H3') out += '\n### ' + node.textContent.trim() + '\n\n';
        else if (tag === 'H4') out += '\n#### ' + node.textContent.trim() + '\n\n';
        else if (tag === 'P') out += node.textContent.trim() + '\n\n';
        else if (tag === 'LI') out += '- ' + node.textContent.trim() + '\n';
        else if (tag === 'BR') out += '\n';
        else if (tag === 'PRE' || tag === 'CODE') out += '\n```\n' + node.textContent + '\n```\n\n';
        else if (tag === 'BLOCKQUOTE') out += '> ' + node.textContent.trim() + '\n\n';
        else if (tag === 'A') {
          var href = node.getAttribute('href');
          var text = node.textContent.trim();
          if (href && text) out += '[' + text + '](' + href + ')';
          else out += text;
        }
        else if (tag === 'IMG') {
          var alt = node.getAttribute('alt') || '';
          var src = node.getAttribute('src') || '';
          if (src) out += '![' + alt + '](' + src + ')\n';
        }
        else out += toMarkdown(node);
      }
    }
    return out;
  }

  var content = toMarkdown(source)
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  // Collect visible links
  var links = [];
  var anchors = document.querySelectorAll('a[href]');
  for (var i = 0; i < anchors.length && links.length < 100; i++) {
    var a = anchors[i];
    var rect = a.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) continue;
    var text = a.textContent.trim();
    if (!text || text.length > 200) continue;
    var href = a.href;
    if (href && !href.startsWith('javascript:')) {
      links.push({text: text.substring(0, 100), href: href});
    }
  }

  return JSON.stringify({
    url: location.href,
    title: document.title,
    content: content,
    links: links,
    meta: meta
  });
})();
```

**Step 2: Update Makefile — add extract_js.inc generation**

Add after the focus_js.inc rule:

```makefile
extract_js.inc: js/extract.js
	@echo "Generating extract_js.inc"
	@sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$$/\\n"/' js/extract.js > extract_js.inc
```

Update the swim target dependencies:

```makefile
swim: $(SRC) $(HEADERS) focus_js.inc extract_js.inc Info.plist
```

Update clean:

```makefile
clean:
	rm -f swim swim-mcp focus_js.inc extract_js.inc
```

**Step 3: Add do_extract to serve.m**

Add at the top of serve.m, after the includes:

```c
static const char *kExtractJS =
#include "extract_js.inc"
;
```

Add the handler function (after `do_eval`):

```c
static NSDictionary *do_extract(ServeContext *ctx) {
    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

        __block NSDictionary *response = nil;
        __block BOOL done = NO;

        NSString *js = [NSString stringWithUTF8String:kExtractJS];
        [wv evaluateJavaScript:js completionHandler:^(id res, NSError *error) {
            if (error) {
                response = @{@"ok": @NO, @"error": error.localizedDescription ?: @"unknown"};
            } else if (res && [res isKindOfClass:[NSString class]]) {
                NSData *data = [(NSString *)res dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (parsed) {
                    NSMutableDictionary *r = [parsed mutableCopy];
                    r[@"ok"] = @YES;
                    response = r;
                } else {
                    response = @{@"ok": @NO, @"error": @"parse failed"};
                }
            } else {
                response = @{@"ok": @NO, @"error": @"no result"};
            }
            done = YES;
        }];

        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:timeout]) {
            if ([timeout timeIntervalSinceNow] <= 0) break;
        }

        if (!done) result = @{@"ok": @NO, @"error": @"extract timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"extract failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"extract failed"};
}
```

**Step 4: Add route handler and wire it up**

Add HTTP handler:

```c
static void handle_extract(int fd, ServeContext *ctx) {
    send_dict(fd, do_extract(ctx));
}
```

Add to the routing `if/else` chain in `server_thread`:

```c
} else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/extract") == 0) {
    handle_extract(client_fd, ctx);
}
```

Also add to the batch handler's type dispatch:

```c
} else if ([type isEqualToString:@"extract"]) {
    result = do_extract(ctx);
}
```

**Step 5: Build and test**

```bash
make clean && make
```

Test:

```bash
# Terminal 1:
./swim --serve 9111 https://example.com

# Terminal 2 (wait for page to load):
curl -s http://localhost:9111/extract | python3 -m json.tool
```

Expected: JSON with `url`, `title`, `content` (markdown), `links`, `meta`.

**Step 6: Commit**

```bash
git add js/extract.js serve.m Makefile
git commit -m "Add /extract endpoint for content extraction"
```

---

### Task 3: Add /click endpoint

Click elements by CSS selector or text content match.

**Files:**
- Modify: `serve.m` — add do_click, handle_click, wire route

**Step 1: Add do_click to serve.m**

```c
static NSDictionary *do_click(NSDictionary *json, ServeContext *ctx) {
    NSString *selector = json[@"selector"];
    NSString *text = json[@"text"];
    if (!selector && !text) return @{@"ok": @NO, @"error": @"missing selector or text"};

    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

        NSString *js;
        if (selector) {
            // Escape single quotes in selector
            NSString *escaped = [selector stringByReplacingOccurrencesOfString:@"'"
                                                                   withString:@"\\'"];
            js = [NSString stringWithFormat:
                @"(function(){"
                "var el=document.querySelector('%@');"
                "if(!el)return JSON.stringify({ok:false,error:'element not found'});"
                "el.click();return JSON.stringify({ok:true})"
                "})()", escaped];
        } else {
            NSString *escaped = [text stringByReplacingOccurrencesOfString:@"'"
                                                               withString:@"\\'"];
            js = [NSString stringWithFormat:
                @"(function(){"
                "var els=document.querySelectorAll('a,button,input,[role=button],[onclick]');"
                "for(var i=0;i<els.length;i++){"
                "  if(els[i].textContent.trim().indexOf('%@')!==-1){"
                "    els[i].click();return JSON.stringify({ok:true})}}"
                "return JSON.stringify({ok:false,error:'no element with matching text'})"
                "})()", escaped];
        }

        __block BOOL done = NO;
        __block NSDictionary *response = nil;

        [wv evaluateJavaScript:js completionHandler:^(id res, NSError *error) {
            if (error) {
                response = @{@"ok": @NO, @"error": error.localizedDescription ?: @"unknown"};
            } else if (res && [res isKindOfClass:[NSString class]]) {
                NSData *data = [(NSString *)res dataUsingEncoding:NSUTF8StringEncoding];
                response = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
            done = YES;
        }];

        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:timeout]) {
            if ([timeout timeIntervalSinceNow] <= 0) break;
        }

        if (!done) result = @{@"ok": @NO, @"error": @"click timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"click failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"click failed"};
}
```

**Step 2: Add route handler and wire up**

```c
static void handle_click(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_click(json, ctx));
}
```

Add to routing:

```c
} else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/click") == 0) {
    handle_click(client_fd, &req, ctx);
}
```

Add to batch handler:

```c
} else if ([type isEqualToString:@"click"]) {
    result = do_click(step, ctx);
}
```

**Step 3: Build and test**

```bash
make clean && make
```

Test:

```bash
# Terminal 1:
./swim --serve 9111 https://example.com

# Terminal 2:
curl -s -X POST http://localhost:9111/click \
  -d '{"selector":"a"}' | python3 -m json.tool
# Expected: {"ok":true}

curl -s -X POST http://localhost:9111/click \
  -d '{"text":"More information"}' | python3 -m json.tool
# Expected: {"ok":true}
```

**Step 4: Commit**

```bash
git add serve.m
git commit -m "Add /click endpoint for element interaction"
```

---

### Task 4: Build swim-mcp binary

Standalone pure C binary. Reads MCP JSON-RPC on stdin, writes responses on stdout, translates tool calls to HTTP requests against `swim --serve`.

**Files:**
- Create: `swim-mcp.c` — MCP stdio ↔ HTTP bridge
- Modify: `Makefile` — add swim-mcp target

**Step 1: Create swim-mcp.c**

This is the largest new file. It implements:
- MCP JSON-RPC protocol (initialize, tools/list, tools/call)
- HTTP client (connect to swim --serve, send request, read response)
- Tool definitions matching the design doc

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// --- Configuration ---

static int g_port = 9111;

// --- Simple JSON helpers (no dependencies) ---

// Find a string value for a key in a JSON object (simple flat parser)
// Returns malloc'd string or NULL. Caller must free.
static char *json_get_string(const char *json, const char *key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return NULL;
    p += strlen(search);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (*p != '"') return NULL;
    p++;
    const char *end = p;
    while (*end && *end != '"') {
        if (*end == '\\') end++;
        end++;
    }
    int len = (int)(end - p);
    char *result = malloc(len + 1);
    memcpy(result, p, len);
    result[len] = '\0';
    return result;
}

// Find an integer value for a key
static bool json_get_int(const char *json, const char *key, int *out) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return false;
    p += strlen(search);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (*p != '-' && (*p < '0' || *p > '9')) return false;
    *out = atoi(p);
    return true;
}

// Extract the "params" object as a raw substring
static char *json_get_object(const char *json, const char *key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return NULL;
    p += strlen(search);
    while (*p && *p != '{') p++;
    if (*p != '{') return NULL;

    int depth = 0;
    const char *start = p;
    while (*p) {
        if (*p == '{') depth++;
        else if (*p == '}') { depth--; if (depth == 0) { p++; break; } }
        else if (*p == '"') { p++; while (*p && *p != '"') { if (*p == '\\') p++; p++; } }
        p++;
    }
    int len = (int)(p - start);
    char *result = malloc(len + 1);
    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

// --- HTTP Client ---

static char *http_request(const char *method, const char *path,
                          const char *body, int *out_len) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NULL;

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(g_port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return NULL;
    }

    // Send request
    char header[1024];
    int body_len = body ? (int)strlen(body) : 0;
    int hlen = snprintf(header, sizeof(header),
        "%s %s HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n",
        method, path, body_len);

    write(fd, header, hlen);
    if (body && body_len > 0) write(fd, body, body_len);

    // Read response
    int cap = 65536;
    char *buf = malloc(cap);
    int total = 0;
    while (1) {
        if (total >= cap - 1) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
        int n = (int)read(fd, buf + total, cap - 1 - total);
        if (n <= 0) break;
        total += n;
    }
    buf[total] = '\0';
    close(fd);

    // Skip HTTP headers, find body
    char *body_start = strstr(buf, "\r\n\r\n");
    if (!body_start) { free(buf); return NULL; }
    body_start += 4;

    int resp_len = total - (int)(body_start - buf);
    char *result = malloc(resp_len + 1);
    memcpy(result, body_start, resp_len);
    result[resp_len] = '\0';
    if (out_len) *out_len = resp_len;

    free(buf);
    return result;
}

static char *http_get(const char *path) {
    return http_request("GET", path, NULL, NULL);
}

static char *http_post(const char *path, const char *body) {
    return http_request("POST", path, body, NULL);
}

// Get raw binary response (for screenshots)
static char *http_get_raw(const char *path, int *out_len) {
    return http_request("GET", path, NULL, out_len);
}

// --- MCP Protocol ---

static void send_mcp(const char *json) {
    int len = (int)strlen(json);
    printf("Content-Length: %d\r\n\r\n%s", len, json);
    fflush(stdout);
}

static void send_mcp_result(const char *id_str, int id_int, bool id_is_string,
                            const char *result_json) {
    char buf[131072];
    if (id_is_string) {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":\"%s\",\"result\":%s}",
            id_str, result_json);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":%s}",
            id_int, result_json);
    }
    send_mcp(buf);
}

static void send_mcp_error(const char *id_str, int id_int, bool id_is_string,
                           int code, const char *message) {
    char buf[4096];
    if (id_is_string) {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":\"%s\","
            "\"error\":{\"code\":%d,\"message\":\"%s\"}}",
            id_str, code, message);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":%d,"
            "\"error\":{\"code\":%d,\"message\":\"%s\"}}",
            id_int, code, message);
    }
    send_mcp(buf);
}

// --- Tool Definitions ---

static const char *kToolsList =
    "{\"tools\":["
    "{\"name\":\"navigate\","
    "\"description\":\"Navigate to a URL in the active tab\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"URL to navigate to\"}},"
    "\"required\":[\"url\"]}},"

    "{\"name\":\"screenshot\","
    "\"description\":\"Capture a PNG screenshot of the current page\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"

    "{\"name\":\"extract\","
    "\"description\":\"Extract page content as markdown with links and metadata\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"

    "{\"name\":\"execute\","
    "\"description\":\"Run a swim command (e.g. 'tabopen url', 'bookmark', 'session save name')\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Command to execute\"}},"
    "\"required\":[\"command\"]}},"

    "{\"name\":\"action\","
    "\"description\":\"Trigger a keybinding action (e.g. 'scroll-down', 'hint-follow', 'reload')\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"action\":{\"type\":\"string\",\"description\":\"Action name\"},"
    "\"count\":{\"type\":\"integer\",\"description\":\"Repeat count\"}},"
    "\"required\":[\"action\"]}},"

    "{\"name\":\"state\","
    "\"description\":\"Get browser state: mode, URL, title, tab list\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"

    "{\"name\":\"click\","
    "\"description\":\"Click an element by CSS selector or text content\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{"
    "\"selector\":{\"type\":\"string\",\"description\":\"CSS selector\"},"
    "\"text\":{\"type\":\"string\",\"description\":\"Text content to match\"}}}},"

    "{\"name\":\"key\","
    "\"description\":\"Send a keypress (e.g. 'j', 'Escape', 'Ctrl-D')\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"key\":{\"type\":\"string\",\"description\":\"Key to send\"}},"
    "\"required\":[\"key\"]}}"
    "]}";

// --- Tool Call Handlers ---

static char *handle_tool_call(const char *name, const char *arguments) {
    if (strcmp(name, "navigate") == 0) {
        char *url = json_get_string(arguments, "url");
        if (!url) return strdup("{\"error\":\"missing url\"}");
        char body[4096];
        snprintf(body, sizeof(body), "{\"command\":\"open %s\"}", url);
        free(url);
        char *resp = http_post("/command", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "screenshot") == 0) {
        int len = 0;
        char *raw = http_get_raw("/screenshot", &len);
        if (!raw || len <= 0) {
            free(raw);
            return strdup("{\"error\":\"screenshot failed\"}");
        }
        // Return as base64 — MCP image content
        // For now return the JSON endpoint instead
        char *resp = http_get("/screenshot");
        free(raw);
        // The /screenshot GET returns raw PNG, use the batch endpoint
        char *batch = http_post("/batch",
            "[{\"type\":\"screenshot\"}]");
        return batch ? batch : strdup("{\"error\":\"screenshot failed\"}");
    }

    if (strcmp(name, "extract") == 0) {
        char *resp = http_get("/extract");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "execute") == 0) {
        char *cmd = json_get_string(arguments, "command");
        if (!cmd) return strdup("{\"error\":\"missing command\"}");
        char body[4096];
        // Escape quotes in command
        char escaped[2048];
        int j = 0;
        for (int i = 0; cmd[i] && j < 2046; i++) {
            if (cmd[i] == '"' || cmd[i] == '\\') escaped[j++] = '\\';
            escaped[j++] = cmd[i];
        }
        escaped[j] = '\0';
        snprintf(body, sizeof(body), "{\"command\":\"%s\"}", escaped);
        free(cmd);
        char *resp = http_post("/command", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "action") == 0) {
        char *action = json_get_string(arguments, "action");
        if (!action) return strdup("{\"error\":\"missing action\"}");
        int count = 0;
        bool has_count = json_get_int(arguments, "count", &count);
        char body[512];
        if (has_count && count > 0) {
            snprintf(body, sizeof(body),
                "{\"action\":\"%s\",\"count\":%d}", action, count);
        } else {
            snprintf(body, sizeof(body), "{\"action\":\"%s\"}", action);
        }
        free(action);
        char *resp = http_post("/action", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "state") == 0) {
        char *resp = http_get("/state");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "click") == 0) {
        char *selector = json_get_string(arguments, "selector");
        char *text = json_get_string(arguments, "text");
        char body[4096];
        if (selector) {
            char escaped[2048];
            int j = 0;
            for (int i = 0; selector[i] && j < 2046; i++) {
                if (selector[i] == '"' || selector[i] == '\\') escaped[j++] = '\\';
                escaped[j++] = selector[i];
            }
            escaped[j] = '\0';
            snprintf(body, sizeof(body), "{\"selector\":\"%s\"}", escaped);
        } else if (text) {
            char escaped[2048];
            int j = 0;
            for (int i = 0; text[i] && j < 2046; i++) {
                if (text[i] == '"' || text[i] == '\\') escaped[j++] = '\\';
                escaped[j++] = text[i];
            }
            escaped[j] = '\0';
            snprintf(body, sizeof(body), "{\"text\":\"%s\"}", escaped);
        } else {
            free(selector); free(text);
            return strdup("{\"error\":\"missing selector or text\"}");
        }
        free(selector); free(text);
        char *resp = http_post("/click", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "key") == 0) {
        char *key = json_get_string(arguments, "key");
        if (!key) return strdup("{\"error\":\"missing key\"}");
        char body[256];
        snprintf(body, sizeof(body), "{\"key\":\"%s\"}", key);
        free(key);
        char *resp = http_post("/key", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    return strdup("{\"error\":\"unknown tool\"}");
}

// --- Read MCP message from stdin ---

static char *read_mcp_message(void) {
    // Read Content-Length header
    char line[256];
    int content_length = 0;

    while (fgets(line, sizeof(line), stdin)) {
        if (strncmp(line, "Content-Length:", 15) == 0) {
            content_length = atoi(line + 15);
        }
        // Empty line = end of headers
        if (strcmp(line, "\r\n") == 0 || strcmp(line, "\n") == 0) break;
    }

    if (content_length <= 0 || content_length > 10485760) return NULL;

    char *body = malloc(content_length + 1);
    int total = 0;
    while (total < content_length) {
        int n = (int)fread(body + total, 1, content_length - total, stdin);
        if (n <= 0) { free(body); return NULL; }
        total += n;
    }
    body[content_length] = '\0';
    return body;
}

// --- Main ---

int main(int argc, char *argv[]) {
    // Parse args
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            g_port = atoi(argv[++i]);
        }
    }

    // Log to stderr (stdout is MCP protocol)
    fprintf(stderr, "swim-mcp: connecting to swim on port %d\n", g_port);

    // MCP message loop
    while (1) {
        char *msg = read_mcp_message();
        if (!msg) break;

        char *method = json_get_string(msg, "method");
        char *id_str = json_get_string(msg, "id");
        int id_int = 0;
        bool id_is_string = (id_str != NULL);
        if (!id_is_string) json_get_int(msg, "id", &id_int);

        if (!method) {
            free(msg);
            free(id_str);
            continue;
        }

        if (strcmp(method, "initialize") == 0) {
            send_mcp_result(id_str, id_int, id_is_string,
                "{\"protocolVersion\":\"2024-11-05\","
                "\"capabilities\":{\"tools\":{}},"
                "\"serverInfo\":{\"name\":\"swim-mcp\",\"version\":\"0.1.0\"}}");
        } else if (strcmp(method, "notifications/initialized") == 0) {
            // No response needed for notifications
        } else if (strcmp(method, "tools/list") == 0) {
            send_mcp_result(id_str, id_int, id_is_string, kToolsList);
        } else if (strcmp(method, "tools/call") == 0) {
            char *params = json_get_object(msg, "params");
            char *name = params ? json_get_string(params, "name") : NULL;
            char *arguments = params ? json_get_object(params, "arguments") : NULL;

            if (!name) {
                send_mcp_error(id_str, id_int, id_is_string,
                    -32602, "missing tool name");
            } else {
                char *result = handle_tool_call(name, arguments ? arguments : "{}");
                // Wrap result as MCP text content
                // Escape the result for embedding in JSON
                int rlen = (int)strlen(result);
                int cap = rlen * 2 + 256;
                char *escaped = malloc(cap);
                int j = 0;
                for (int i = 0; i < rlen && j < cap - 2; i++) {
                    if (result[i] == '"' || result[i] == '\\') escaped[j++] = '\\';
                    else if (result[i] == '\n') { escaped[j++] = '\\'; escaped[j++] = 'n'; continue; }
                    else if (result[i] == '\r') { escaped[j++] = '\\'; escaped[j++] = 'r'; continue; }
                    else if (result[i] == '\t') { escaped[j++] = '\\'; escaped[j++] = 't'; continue; }
                    escaped[j++] = result[i];
                }
                escaped[j] = '\0';

                int buf_size = j + 512;
                char *response = malloc(buf_size);
                snprintf(response, buf_size,
                    "{\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}",
                    escaped);

                send_mcp_result(id_str, id_int, id_is_string, response);
                free(result);
                free(escaped);
                free(response);
            }

            free(params);
            free(name);
            free(arguments);
        } else {
            if (id_str || id_int) {
                send_mcp_error(id_str, id_int, id_is_string,
                    -32601, "method not found");
            }
        }

        free(method);
        free(id_str);
        free(msg);
    }

    return 0;
}
```

**Step 2: Update Makefile — add swim-mcp target**

Add after the swim target:

```makefile
swim-mcp: swim-mcp.c
	$(CC) -Wall -Wextra -Wpedantic -std=c17 swim-mcp.c -o swim-mcp
```

Update the `all` target and clean:

```makefile
all: swim swim-mcp

clean:
	rm -f swim swim-mcp focus_js.inc extract_js.inc

.PHONY: clean all
```

**Step 3: Build**

```bash
make clean && make all
```

Expected: Both `swim` (217KB~) and `swim-mcp` (small, ~30KB) built.

**Step 4: Test manually**

```bash
# Terminal 1: start swim
./swim --serve 9111 https://example.com

# Terminal 2: test swim-mcp directly
echo 'Content-Length: 61\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./swim-mcp --port 9111
```

Expected: MCP initialize response on stdout.

**Step 5: Test with Claude Code**

Add to `~/.claude/mcp.json`:

```json
{
  "mcpServers": {
    "swim": {
      "command": "/path/to/swim-mcp",
      "args": ["--port", "9111"]
    }
  }
}
```

Start swim with `./swim --serve 9111`, then in Claude Code ask it to use the swim tools.

**Step 6: Commit**

```bash
git add swim-mcp.c Makefile
git commit -m "Add swim-mcp: MCP server sidecar for AI tool integration"
```

---

### Task 5: Integration test and documentation

**Files:**
- Modify: `CLAUDE.md` — document --serve and swim-mcp
- Modify: `docs/ROADMAP.md` — mark Phase 1.1 and 1.3 as shipped

**Step 1: Update CLAUDE.md**

Add section:

```markdown
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
```

**Step 2: End-to-end test**

```bash
# 1. Build everything
make clean && make all

# 2. Start swim
./swim --serve 9111

# 3. Test all new endpoints
curl -s http://localhost:9111/health
curl -s http://localhost:9111/state | python3 -m json.tool
curl -s http://localhost:9111/extract | python3 -m json.tool
curl -s -X POST http://localhost:9111/click -d '{"selector":"a"}'
curl -s http://localhost:9111/screenshot -o /tmp/swim.png

# 4. Verify binary sizes
ls -lh swim swim-mcp
```

**Step 3: Commit**

```bash
git add CLAUDE.md docs/ROADMAP.md
git commit -m "Document --serve API and MCP integration"
```

---

Plan complete and saved to `docs/plans/2026-03-09-ai-native-platform.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints

Which approach?