# Test Server Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an HTTP test server (`--test-server <port>`) so an AI agent can drive swim remotely — send actions, take screenshots, inspect state. All test code compiles out of release builds via `#ifdef SWIM_TEST`.

**Architecture:** BSD socket server on a background pthread, dispatching all UI/browser work to the main thread via `dispatch_sync`. JSON parsing via NSJSONSerialization. Single-connection serial processing.

**Tech Stack:** C/Objective-C, BSD sockets, pthread, WKWebView snapshot API, NSJSONSerialization

---

### Task 1: Makefile `test-ui` target

**Files:**
- Modify: `Makefile`

**Step 1: Add `test-ui` target**

```makefile
test-ui: $(SRC) test_server.m test_server.h browser.h input.h commands.h ui.h storage.h config.h Info.plist
	$(CC) $(CFLAGS) -DSWIM_TEST $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist $(SRC) test_server.m -o swim-test

.PHONY: clean test-ui
```

**Step 2: Verify `make` still works without test code**

Run: `make clean && make`
Expected: Builds `swim` with no errors, no test symbols.

Run: `nm swim | grep -i test_server`
Expected: No output (test code not linked).

**Step 3: Commit**

```bash
git add Makefile
git commit -m "Add test-ui Makefile target with -DSWIM_TEST"
```

---

### Task 2: test_server.h — TestContext struct and API

**Files:**
- Create: `test_server.h`

**Step 1: Create header**

```c
#ifndef SWIM_TEST_SERVER_H
#define SWIM_TEST_SERVER_H

#ifdef SWIM_TEST

#include "ui.h"
#include "browser.h"
#include "input.h"
#include "commands.h"

typedef struct TestContext {
    SwimUI *ui;
    Browser *browser;
    ModeManager *mode;
    CommandRegistry *commands;
    void (*handle_action)(const char *action, void *ctx);
    void *action_ctx;
} TestContext;

// Starts HTTP server on given port in a background thread.
// ctx must remain valid for the lifetime of the server (stack-allocated in main is fine
// since main never returns — NSApp run loops forever).
void test_server_start(int port, TestContext *ctx);

#endif // SWIM_TEST
#endif // SWIM_TEST_SERVER_H
```

**Step 2: Commit**

```bash
git add test_server.h
git commit -m "Add test_server.h with TestContext struct"
```

---

### Task 3: ui_screenshot — WKWebView snapshot

**Files:**
- Modify: `ui.h` (add declaration)
- Modify: `ui.m` (add implementation)

**Step 1: Add declaration to ui.h**

At the end of `ui.h`, before `#endif`, add:

```c
#ifdef SWIM_TEST
// Capture active tab's webview content as PNG. Returns NSData* (cast to void*).
// Must be called from the main thread. The completion handler for
// takeSnapshotWithConfiguration fires on the main thread, so this function
// spins the run loop instead of using a semaphore (which would deadlock).
void *ui_screenshot(SwimUI *ui);
#endif
```

**Step 2: Add implementation to ui.m**

At the end of `ui.m`, before the final closing brace or at file end:

```objc
#ifdef SWIM_TEST
void *ui_screenshot(SwimUI *ui) {
    if (ui->active_tab < 0 || ui->active_tab >= ui->tab_count) return NULL;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    if (!wv) return NULL;

    __block NSData *result = nil;
    __block BOOL done = NO;

    WKSnapshotConfiguration *config = [[WKSnapshotConfiguration alloc] init];
    [wv takeSnapshotWithConfiguration:config
                    completionHandler:^(NSImage *image, NSError *error) {
        (void)error;
        if (image) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
                initWithData:[image TIFFRepresentation]];
            result = [rep representationUsingType:NSBitmapImageFileTypePNG
                                       properties:@{}];
        }
        done = YES;
    }];

    // Spin run loop — we're on the main thread, and the completion handler
    // also delivers on the main thread, so a semaphore would deadlock.
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                            beforeDate:timeout]) {
        if ([timeout timeIntervalSinceNow] <= 0) break;
    }

    return (__bridge_retained void *)result;
}
#endif
```

Key design decision: We spin the run loop instead of using `dispatch_semaphore_wait` because `takeSnapshotWithConfiguration:` delivers its callback on the main thread. A semaphore would deadlock since we're already on the main thread (dispatched via `dispatch_sync` from the server thread). Spinning the run loop lets the callback fire.

**Step 3: Verify compilation**

Run: `make clean && make`
Expected: Builds without test code (no errors, no warnings from ifdef'd code).

**Step 4: Commit**

```bash
git add ui.h ui.m
git commit -m "Add ui_screenshot for test server webview capture"
```

---

### Task 4: test_server.m — HTTP server with all endpoints

**Files:**
- Create: `test_server.m`

**Step 1: Create the server implementation**

The server needs:
1. BSD socket accept loop on a background pthread
2. HTTP request parsing (method, path, body)
3. Route to handler functions
4. Each handler dispatches to main thread via `dispatch_sync`, collects result, sends HTTP response
5. JSON responses via `snprintf`, JSON request parsing via `NSJSONSerialization`

```objc
#ifdef SWIM_TEST

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>
#include <unistd.h>
#include "test_server.h"

// --- HTTP helpers ---

static void send_response(int fd, int status, const char *content_type,
                          const void *body, int body_len) {
    const char *status_text = (status == 200) ? "OK" : "Bad Request";
    char header[512];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n",
        status, status_text, content_type, body_len);
    write(fd, header, hlen);
    if (body && body_len > 0) write(fd, body, body_len);
}

static void send_json(int fd, int status, const char *json) {
    send_response(fd, status, "application/json", json, (int)strlen(json));
}

// --- Request parsing ---

typedef struct {
    char method[8];
    char path[256];
    char *body;
    int body_len;
} HTTPRequest;

static bool parse_request(int fd, HTTPRequest *req) {
    char buf[8192];
    int total = 0;
    // Read headers (look for \r\n\r\n)
    while (total < (int)sizeof(buf) - 1) {
        int n = (int)read(fd, buf + total, sizeof(buf) - 1 - total);
        if (n <= 0) return false;
        total += n;
        buf[total] = '\0';
        if (strstr(buf, "\r\n\r\n")) break;
    }

    // Parse request line
    sscanf(buf, "%7s %255s", req->method, req->path);

    // Find body start
    char *body_start = strstr(buf, "\r\n\r\n");
    if (!body_start) return false;
    body_start += 4;

    // Get Content-Length
    int content_length = 0;
    char *cl = strcasestr(buf, "Content-Length:");
    if (cl) content_length = atoi(cl + 15);

    int body_have = total - (int)(body_start - buf);

    if (content_length > 0) {
        req->body = malloc(content_length + 1);
        memcpy(req->body, body_start, body_have);
        // Read remaining body
        while (body_have < content_length) {
            int n = (int)read(fd, req->body + body_have, content_length - body_have);
            if (n <= 0) break;
            body_have += n;
        }
        req->body[body_have] = '\0';
        req->body_len = body_have;
    } else {
        req->body = NULL;
        req->body_len = 0;
    }

    return true;
}

// --- JSON parsing helpers (using NSJSONSerialization) ---

static NSDictionary *parse_json_body(const char *body, int len) {
    if (!body || len <= 0) return nil;
    NSData *data = [NSData dataWithBytes:body length:len];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

// --- Route handlers ---

static void handle_health(int fd) {
    send_json(fd, 200, "{\"ok\":true}");
}

static void handle_action(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSString *action = json[@"action"];
    if (!action) { send_json(fd, 400, "{\"error\":\"missing action\"}"); return; }

    NSNumber *count = json[@"count"];

    __block bool ok = true;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (count) ctx->mode->count = [count intValue];
        ctx->handle_action([action UTF8String], ctx->action_ctx);
        ctx->mode->count = 0;
    });

    send_json(fd, 200, ok ? "{\"ok\":true}" : "{\"ok\":false}");
}

static void handle_command(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSString *command = json[@"command"];
    if (!command) { send_json(fd, 400, "{\"error\":\"missing command\"}"); return; }

    __block bool ok = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = registry_exec(ctx->commands, [command UTF8String]);
    });

    send_json(fd, 200, ok ? "{\"ok\":true}" : "{\"ok\":false}");
}

static void handle_key(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSString *key = json[@"key"];
    if (!key) { send_json(fd, 400, "{\"error\":\"missing key\"}"); return; }

    NSNumber *mods = json[@"modifiers"];
    unsigned int modifiers = mods ? [mods unsignedIntValue] : 0;

    __block bool consumed = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        consumed = mode_handle_key(ctx->mode, [key UTF8String], modifiers);
    });

    send_json(fd, 200, consumed ? "{\"consumed\":true}" : "{\"consumed\":false}");
}

static void handle_screenshot(int fd, TestContext *ctx) {
    __block NSData *png = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        void *data = ui_screenshot(ctx->ui);
        if (data) png = (__bridge_transfer NSData *)data;
    });

    if (png) {
        send_response(fd, 200, "image/png", [png bytes], (int)[png length]);
    } else {
        send_json(fd, 500, "{\"error\":\"screenshot failed\"}");
    }
}

static void handle_state(int fd, TestContext *ctx) {
    __block NSString *json = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        const char *mode_str = "NORMAL";
        switch (ctx->mode->mode) {
            case MODE_NORMAL:      mode_str = "NORMAL"; break;
            case MODE_INSERT:      mode_str = "INSERT"; break;
            case MODE_COMMAND:     mode_str = "COMMAND"; break;
            case MODE_HINT:        mode_str = "HINT"; break;
            case MODE_PASSTHROUGH: mode_str = "PASSTHROUGH"; break;
        }

        Tab *active = browser_active(ctx->browser);
        NSMutableArray *tabs = [NSMutableArray array];
        for (int i = 0; i < ctx->browser->tab_count; i++) {
            Tab *t = &ctx->browser->tabs[i];
            [tabs addObject:@{
                @"url": [NSString stringWithUTF8String:t->url],
                @"title": [NSString stringWithUTF8String:t->title],
                @"lazy": @(t->lazy),
            }];
        }

        NSDictionary *state = @{
            @"mode": [NSString stringWithUTF8String:mode_str],
            @"url": active ? [NSString stringWithUTF8String:active->url] : @"",
            @"title": active ? [NSString stringWithUTF8String:active->title] : @"",
            @"tab_count": @(ctx->browser->tab_count),
            @"active_tab": @(ctx->browser->active_tab),
            @"tabs": tabs,
            @"pending_keys": [NSString stringWithUTF8String:ctx->mode->pending_keys],
            @"count": @(ctx->mode->count),
        };

        NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
        if (data) json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    });

    if (json) {
        send_json(fd, 200, [json UTF8String]);
    } else {
        send_json(fd, 500, "{\"error\":\"state serialization failed\"}");
    }
}

static void handle_resize(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSNumber *width = json[@"width"];
    NSNumber *height = json[@"height"];
    if (!width || !height) {
        send_json(fd, 400, "{\"error\":\"missing width/height\"}");
        return;
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSWindow *window = (__bridge NSWindow *)ui_get_window(ctx->ui);
        NSRect frame = [window frame];
        frame.size.width = [width doubleValue];
        frame.size.height = [height doubleValue];
        [window setFrame:frame display:YES animate:NO];
    });

    send_json(fd, 200, "{\"ok\":true}");
}

// --- Server thread ---

static void *server_thread(void *arg) {
    TestContext *ctx = (TestContext *)arg;
    int server_fd = (int)(intptr_t)ctx->_server_fd;

    while (1) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) continue;

        HTTPRequest req = {0};
        if (!parse_request(client_fd, &req)) {
            close(client_fd);
            continue;
        }

        // Route
        if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/health") == 0) {
            handle_health(client_fd);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/action") == 0) {
            handle_action(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/command") == 0) {
            handle_command(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/key") == 0) {
            handle_key(client_fd, &req, ctx);
        } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/screenshot") == 0) {
            handle_screenshot(client_fd, ctx);
        } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/state") == 0) {
            handle_state(client_fd, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/resize") == 0) {
            handle_resize(client_fd, &req, ctx);
        } else {
            send_json(client_fd, 404, "{\"error\":\"not found\"}");
        }

        free(req.body);
        close(client_fd);
    }
    return NULL;
}

// --- Public API ---

void test_server_start(int port, TestContext *ctx) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return; }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),  // localhost only
    };

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(fd); return;
    }
    if (listen(fd, 5) < 0) {
        perror("listen"); close(fd); return;
    }

    fprintf(stderr, "Test server listening on port %d\n", port);

    // Store server_fd so thread can use it — stash in a static since
    // TestContext doesn't have a field for it
    static int s_server_fd;
    s_server_fd = fd;

    pthread_t tid;
    // Pass both ctx and fd to thread — use a small struct
    typedef struct { TestContext *ctx; int fd; } ThreadArg;
    static ThreadArg arg;
    arg.ctx = ctx;
    arg.fd = fd;

    pthread_create(&tid, NULL, ^void *(void *a) {
        ThreadArg *ta = (ThreadArg *)a;
        TestContext *tc = ta->ctx;
        int server_fd = ta->fd;

        while (1) {
            int client_fd = accept(server_fd, NULL, NULL);
            if (client_fd < 0) continue;

            HTTPRequest req = {0};
            if (!parse_request(client_fd, &req)) {
                close(client_fd);
                continue;
            }

            if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/health") == 0) {
                handle_health(client_fd);
            } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/action") == 0) {
                handle_action(client_fd, &req, tc);
            } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/command") == 0) {
                handle_command(client_fd, &req, tc);
            } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/key") == 0) {
                handle_key(client_fd, &req, tc);
            } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/screenshot") == 0) {
                handle_screenshot(client_fd, tc);
            } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/state") == 0) {
                handle_state(client_fd, tc);
            } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/resize") == 0) {
                handle_resize(client_fd, &req, tc);
            } else {
                send_json(client_fd, 404, "{\"error\":\"not found\"}");
            }

            free(req.body);
            close(client_fd);
        }
        return NULL;
    }, &arg);

    pthread_detach(tid);
}

#endif // SWIM_TEST
```

Wait — I made this too complicated with the duplicate routing. Let me simplify. The `server_thread` function handles routing, and `test_server_start` just sets up the socket and spawns the thread. Need a clean way to pass both `ctx` and `fd` to the thread.

Revised clean approach — add `_server_fd` to a static, pass `ctx` to thread:

```objc
#ifdef SWIM_TEST

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>
#include <unistd.h>
#include "test_server.h"

static int g_server_fd;

// [all handler functions as above]

static void *server_thread(void *arg) {
    TestContext *ctx = (TestContext *)arg;

    while (1) {
        int client_fd = accept(g_server_fd, NULL, NULL);
        if (client_fd < 0) continue;

        HTTPRequest req = {0};
        if (!parse_request(client_fd, &req)) {
            close(client_fd);
            continue;
        }

        // Route
        if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/health") == 0) {
            handle_health(client_fd);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/action") == 0) {
            handle_action(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/command") == 0) {
            handle_command(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/key") == 0) {
            handle_key(client_fd, &req, ctx);
        } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/screenshot") == 0) {
            handle_screenshot(client_fd, ctx);
        } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/state") == 0) {
            handle_state(client_fd, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/resize") == 0) {
            handle_resize(client_fd, &req, ctx);
        } else {
            send_json(client_fd, 404, "{\"error\":\"not found\"}");
        }

        free(req.body);
        close(client_fd);
    }
    return NULL;
}

void test_server_start(int port, TestContext *ctx) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return; }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(fd); return;
    }
    if (listen(fd, 5) < 0) {
        perror("listen"); close(fd); return;
    }

    fprintf(stderr, "Test server listening on port %d\n", port);

    g_server_fd = fd;
    pthread_t tid;
    pthread_create(&tid, NULL, server_thread, ctx);
    pthread_detach(tid);
}

#endif
```

Note on `handle_resize`: this needs `ui_get_window()` which doesn't exist yet. We need to add a small accessor to `ui.h`/`ui.m`.

**Step 2: Add `ui_get_window` accessor**

In `ui.h`, alongside the `#ifdef SWIM_TEST` block:

```c
#ifdef SWIM_TEST
void *ui_screenshot(SwimUI *ui);
void *ui_get_window(SwimUI *ui);  // returns NSWindow* as void*
#endif
```

In `ui.m`:

```objc
#ifdef SWIM_TEST
void *ui_get_window(SwimUI *ui) {
    return (__bridge void *)ui->window;
}
#endif
```

**Step 3: Verify it compiles**

Run: `make test-ui`
Expected: Builds `swim-test` binary with no errors.

Run: `make clean && make`
Expected: Builds `swim` with no test code.

**Step 4: Commit**

```bash
git add test_server.m test_server.h ui.h ui.m
git commit -m "Add test server with HTTP endpoints for remote browser control"
```

---

### Task 5: Wire test server into main.m

**Files:**
- Modify: `main.m`

**Step 1: Add test server include and arg parsing**

At the top of `main.m`, after existing includes:

```c
#ifdef SWIM_TEST
#include "test_server.h"
#endif
```

In `main()`, after `[NSApp setActivationPolicy:...]` (line ~768), add flag parsing:

```c
#ifdef SWIM_TEST
    int test_port = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test-server") == 0 && i + 1 < argc) {
            test_port = atoi(argv[++i]);
        }
    }
#endif
```

After UI is created and tabs are opened (after the CLI args / session restore block, around line ~865), before the key event monitor:

```c
#ifdef SWIM_TEST
    if (test_port > 0) {
        // Fixed window size for consistent screenshots
        [app.ui->window setFrame:NSMakeRect(100, 100, 1280, 800) display:YES animate:NO];

        TestContext test_ctx = {
            .ui = app.ui,
            .browser = &app.browser,
            .mode = &app.mode,
            .commands = &app.commands,
            .handle_action = handle_action,
            .action_ctx = &app,
        };
        // test_ctx is stack-allocated but safe: main() never returns
        // because [NSApp run] loops forever.
        test_server_start(test_port, &test_ctx);
    }
#endif
```

Note: `test_ctx` is stack-allocated. This is safe because `[NSApp run]` on line ~920 never returns — the function loops until the app terminates, at which point the process exits. But the `test_server_start` thread references `&test_ctx` which lives on the stack. To be safe, make it `static`:

```c
#ifdef SWIM_TEST
    if (test_port > 0) {
        [app.ui->window setFrame:NSMakeRect(100, 100, 1280, 800) display:YES animate:NO];

        static TestContext test_ctx;
        test_ctx = (TestContext){
            .ui = app.ui,
            .browser = &app.browser,
            .mode = &app.mode,
            .commands = &app.commands,
            .handle_action = handle_action,
            .action_ctx = &app,
        };
        test_server_start(test_port, &test_ctx);
    }
#endif
```

Also need to skip `--test-server` and its arg in the CLI URL parsing loop. Update the existing arg loop:

```c
for (int i = 1; i < argc; i++) {
    if (argv[i][0] == '-') {
#ifdef SWIM_TEST
        if (strcmp(argv[i], "--test-server") == 0 && i + 1 < argc) i++;  // skip port arg
#endif
        continue;
    }
    create_tab(argv[i]);
    opened++;
}
```

**Step 2: Verify full build**

Run: `make test-ui`
Expected: Builds `swim-test`.

Run: `./swim-test --test-server 9111 &`
Then: `curl localhost:9111/health`
Expected: `{"ok":true}`

Run: `curl localhost:9111/state`
Expected: JSON with mode, url, tabs.

Run: `curl localhost:9111/screenshot -o /tmp/test.png && file /tmp/test.png`
Expected: PNG image data.

Kill swim-test, then:

Run: `make clean && make`
Expected: Clean build, no test symbols.

Run: `nm swim | grep -i test_server`
Expected: No output.

**Step 3: Commit**

```bash
git add main.m
git commit -m "Wire --test-server flag into main.m"
```

---

### Task 6: Add `clean` target update

**Files:**
- Modify: `Makefile`

**Step 1: Update clean target**

```makefile
clean:
	rm -f swim swim-test
```

**Step 2: Commit**

```bash
git add Makefile
git commit -m "Clean swim-test binary in make clean"
```

---

### Task 7: End-to-end verification

**Step 1: Full clean build of both targets**

Run: `make clean && make && make test-ui`
Expected: Both `swim` and `swim-test` binaries built.

**Step 2: Verify release binary has no test code**

Run: `nm swim | grep -ci test`
Expected: 0 (or only unrelated symbols).

**Step 3: Run test server and exercise all endpoints**

```bash
./swim-test --test-server 9111 &
sleep 2

# Health
curl -s localhost:9111/health
# Expected: {"ok":true}

# Navigate
curl -s -X POST localhost:9111/command -d '{"command":"open https://example.com"}'
sleep 3

# State
curl -s localhost:9111/state | python3 -m json.tool
# Expected: valid JSON with url containing example.com

# Screenshot
curl -s localhost:9111/screenshot -o /tmp/swim-test.png
file /tmp/swim-test.png
# Expected: PNG image data

# Key
curl -s -X POST localhost:9111/key -d '{"key":"j"}'
# Expected: {"consumed":true}

# Action with count
curl -s -X POST localhost:9111/action -d '{"action":"scroll-down","count":5}'
# Expected: {"ok":true}

# Resize
curl -s -X POST localhost:9111/resize -d '{"width":800,"height":600}'
# Expected: {"ok":true}

kill %1
```

**Step 4: Commit final state**

If any fixes were needed during verification, commit them.

---

## Design Decisions

1. **Run loop spinning vs semaphore for screenshots:** `takeSnapshotWithConfiguration:` delivers its completion handler on the main thread. Since the HTTP handler dispatches to the main thread via `dispatch_sync`, using a semaphore would deadlock. Instead, we spin the run loop with `runMode:beforeDate:` which processes pending callbacks.

2. **NSJSONSerialization vs hand-rolled parsing:** We're already in Obj-C land for the server. NSJSONSerialization handles edge cases (escaped quotes in URLs, unicode) in ~1 line vs ~50 lines of fragile `strstr`/`sscanf` parsing.

3. **Static TestContext:** Stack-allocated would technically work (main never returns), but `static` makes the lifetime guarantee explicit and eliminates any doubt.

4. **Localhost-only binding:** `INADDR_LOOPBACK` ensures the test server is never accessible from the network.

5. **`#ifdef SWIM_TEST` everywhere:** All test code is behind the flag. `make` produces a clean binary, `make test-ui` includes the test server. `nm swim | grep test_server` verifies no leakage.
