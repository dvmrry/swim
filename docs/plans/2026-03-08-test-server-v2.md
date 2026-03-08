# Test Server API v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enhance swim's test server with named key mapping, wait-for-load, JS eval, and batch operations so Claude can drive swim without human intervention.

**Architecture:** All new endpoints follow the existing pattern: parse JSON body on server thread, dispatch UI work to main thread via `dispatch_sync`, send JSON response. Named key translation is a pure C lookup table in test_server.m. Wait-for-load spins the run loop (same pattern as `ui_screenshot`). Batch reuses existing handler logic via internal dispatch functions that return NSDictionary results instead of writing to a socket.

**Tech Stack:** C/Objective-C, BSD sockets, WKWebView `isLoading`/`evaluateJavaScript:`, NSJSONSerialization

---

### Task 1: Named Key Translation

Add a `translate_key` function to `test_server.m` that converts human-readable key names (e.g., "Escape", "Enter", "Ctrl-D") into the raw characters and modifier flags that `mode_handle_key` expects. Modify `handle_key` to call it.

**Files:**
- Modify: `test_server.m:144-158` (handle_key function)

**Step 1: Add the translation function**

Add this above `handle_key` in `test_server.m` (after the `parse_json_body` function, around line 108):

```objc
// --- Named key translation ---

typedef struct {
    const char *name;
    const char *raw;
    unsigned int modifiers;
} KeyMap;

static const KeyMap key_map[] = {
    {"Escape",    "\x1b", 0},
    {"Enter",     "\r",   0},
    {"Return",    "\r",   0},
    {"Tab",       "\t",   0},
    {"Backspace", "\x7f", 0},
    {"Space",     " ",    0},
    {"Delete",    "\x7f", 0},

    // Ctrl combos — raw control character + MOD_CTRL flag
    {"Ctrl-A", "\x01", MOD_CTRL},
    {"Ctrl-B", "\x02", MOD_CTRL},
    {"Ctrl-C", "\x03", MOD_CTRL},
    {"Ctrl-D", "\x04", MOD_CTRL},
    {"Ctrl-E", "\x05", MOD_CTRL},
    {"Ctrl-F", "\x06", MOD_CTRL},
    {"Ctrl-G", "\x07", MOD_CTRL},
    {"Ctrl-H", "\x08", MOD_CTRL},
    {"Ctrl-I", "\x09", MOD_CTRL},
    {"Ctrl-J", "\x0a", MOD_CTRL},
    {"Ctrl-K", "\x0b", MOD_CTRL},
    {"Ctrl-L", "\x0c", MOD_CTRL},
    {"Ctrl-M", "\x0d", MOD_CTRL},
    {"Ctrl-N", "\x0e", MOD_CTRL},
    {"Ctrl-O", "\x0f", MOD_CTRL},
    {"Ctrl-P", "\x10", MOD_CTRL},
    {"Ctrl-Q", "\x11", MOD_CTRL},
    {"Ctrl-R", "\x12", MOD_CTRL},
    {"Ctrl-S", "\x13", MOD_CTRL},
    {"Ctrl-T", "\x14", MOD_CTRL},
    {"Ctrl-U", "\x15", MOD_CTRL},
    {"Ctrl-V", "\x16", MOD_CTRL},
    {"Ctrl-W", "\x17", MOD_CTRL},
    {"Ctrl-X", "\x18", MOD_CTRL},
    {"Ctrl-Y", "\x19", MOD_CTRL},
    {"Ctrl-Z", "\x1a", MOD_CTRL},

    {NULL, NULL, 0}
};

// Translates a key name to raw key string and modifier flags.
// If the name is a single character (e.g., "j"), it passes through unchanged.
// Returns true if translation succeeded (including passthrough).
static bool translate_key(const char *name, const char **out_key, unsigned int *out_mods) {
    for (int i = 0; key_map[i].name; i++) {
        if (strcmp(name, key_map[i].name) == 0) {
            *out_key = key_map[i].raw;
            *out_mods = key_map[i].modifiers;
            return true;
        }
    }
    // Single character or unknown — pass through as-is
    *out_key = name;
    *out_mods = 0;
    return true;
}
```

**Step 2: Update handle_key to use translation**

Replace the current `handle_key` function:

```objc
static void handle_key(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSString *key = json[@"key"];
    if (!key) { send_json(fd, 400, "{\"error\":\"missing key\"}"); return; }

    const char *raw_key;
    unsigned int modifiers;
    translate_key([key UTF8String], &raw_key, &modifiers);

    // Explicit modifiers in JSON override/merge with translated ones
    NSNumber *mods = json[@"modifiers"];
    if (mods) modifiers |= [mods unsignedIntValue];

    __block bool consumed = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        consumed = mode_handle_key(ctx->mode, raw_key, modifiers);
    });

    send_json(fd, 200, consumed ? "{\"consumed\":true}" : "{\"consumed\":false}");
}
```

**Step 3: Verify it compiles and test**

Run: `make test-ui`
Expected: Builds with no errors.

Manual test:
```bash
./swim-test --test-server 9111 &
sleep 2
# Named key
curl -s -X POST localhost:9111/key -d '{"key":"Escape"}'
# Expected: {"consumed":true} or {"consumed":false} (depending on mode)
# Single char (backwards compat)
curl -s -X POST localhost:9111/key -d '{"key":"j"}'
# Expected: {"consumed":true}
# Ctrl combo
curl -s -X POST localhost:9111/key -d '{"key":"Ctrl-D"}'
# Expected: {"consumed":true}
kill %1
```

**Step 4: Commit**

```bash
git add test_server.m
git commit -m "Add named key translation to test server /key endpoint"
```

---

### Task 2: Wait for Page Load Endpoint

Add `POST /wait` that blocks until the active tab finishes loading or a timeout is reached. Uses the same run-loop spinning pattern as `ui_screenshot`.

**Files:**
- Modify: `ui.h` (add `ui_is_loading` declaration)
- Modify: `ui.m` (add `ui_is_loading` implementation)
- Modify: `test_server.m` (add `handle_wait` + route)

**Step 1: Add ui_is_loading accessor**

In `ui.h`, inside the `#ifdef SWIM_TEST` block (before `#endif`):

```c
bool ui_is_loading(SwimUI *ui);
```

In `ui.m`, inside the `#ifdef SWIM_TEST` block at the end:

```objc
bool ui_is_loading(SwimUI *ui) {
    if (ui->active_tab < 0 || ui->active_tab >= ui->tab_count) return false;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    return wv ? [wv isLoading] : false;
}
```

**Step 2: Add handle_wait in test_server.m**

Add after `handle_resize`:

```objc
static void handle_wait(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSNumber *timeout_ms = json[@"timeout"];
    double timeout_sec = timeout_ms ? [timeout_ms doubleValue] / 1000.0 : 10.0;
    if (timeout_sec > 30.0) timeout_sec = 30.0;  // cap at 30s
    if (timeout_sec < 0.1) timeout_sec = 0.1;

    __block bool loaded = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
        while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
            if (!ui_is_loading(ctx->ui)) {
                loaded = true;
                break;
            }
            // Spin the run loop to let WebKit process events
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        // Final check
        if (!loaded) loaded = !ui_is_loading(ctx->ui);
    });

    send_json(fd, 200, loaded ? "{\"ok\":true,\"loaded\":true}"
                               : "{\"ok\":true,\"loaded\":false}");
}
```

**Step 3: Add route in server_thread**

In the routing block, add before the 404 `else`:

```c
} else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/wait") == 0) {
    handle_wait(client_fd, &req, ctx);
```

**Step 4: Verify and test**

Run: `make test-ui`
Expected: Builds with no errors.

Manual test:
```bash
./swim-test --test-server 9111 &
sleep 2
# Navigate and wait
curl -s -X POST localhost:9111/command -d '{"command":"open https://example.com"}'
curl -s -X POST localhost:9111/wait -d '{"timeout":5000}'
# Expected: {"ok":true,"loaded":true}
# Wait when already loaded
curl -s -X POST localhost:9111/wait -d '{}'
# Expected: {"ok":true,"loaded":true} (instant)
kill %1
```

**Step 5: Commit**

```bash
git add ui.h ui.m test_server.m
git commit -m "Add /wait endpoint to block until page load completes"
```

---

### Task 3: JS Eval Endpoint

Add `POST /eval` that runs JavaScript on the active webview and returns the result. Uses `evaluateJavaScript:completionHandler:` with run-loop spinning (same pattern as screenshots).

**Files:**
- Modify: `test_server.m` (add `handle_eval` + route)

**Step 1: Add handle_eval**

Add after `handle_wait`:

```objc
static void handle_eval(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSString *js = json[@"js"];
    if (!js) { send_json(fd, 400, "{\"error\":\"missing js\"}"); return; }

    bool wrap_json = [json[@"json"] boolValue];

    // If json:true, wrap in JSON.stringify so objects/arrays come back as strings
    NSString *eval_js = js;
    if (wrap_json) {
        eval_js = [NSString stringWithFormat:@"JSON.stringify(%@)", js];
    }

    __block NSString *result_json = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (ctx->ui == NULL) return;

        __block NSString *response = nil;
        __block BOOL done = NO;

        // Get active webview — need to access ui internals
        // Use ui_run_js pattern but with completion handler
        // We access the webview through the eval JS API
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) {
            response = @"{\"ok\":false,\"error\":\"no active webview\"}";
            done = YES;
            return;
        }

        [wv evaluateJavaScript:eval_js completionHandler:^(id result, NSError *error) {
            if (error) {
                NSString *errMsg = [error.localizedDescription
                    stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
                response = [NSString stringWithFormat:
                    @"{\"ok\":false,\"error\":\"%@\"}", errMsg];
            } else if (result == nil || [result isKindOfClass:[NSNull class]]) {
                response = @"{\"ok\":true,\"result\":null}";
            } else if ([result isKindOfClass:[NSString class]]) {
                // JSON-encode the string value
                NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"v": result}
                    options:0 error:nil];
                NSString *wrapper = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                // Extract just the value: {"v":"..."} -> "..."
                NSRange r = [wrapper rangeOfString:@":"];
                NSString *val = [wrapper substringWithRange:
                    NSMakeRange(r.location + 1, wrapper.length - r.location - 2)];
                response = [NSString stringWithFormat:@"{\"ok\":true,\"result\":%@}", val];
            } else if ([result isKindOfClass:[NSNumber class]]) {
                // Could be bool or number
                if (strcmp([result objCType], @encode(BOOL)) == 0 ||
                    strcmp([result objCType], @encode(char)) == 0) {
                    response = [NSString stringWithFormat:@"{\"ok\":true,\"result\":%@}",
                        [result boolValue] ? @"true" : @"false"];
                } else {
                    response = [NSString stringWithFormat:@"{\"ok\":true,\"result\":%@}", result];
                }
            } else {
                // Fallback: try description
                response = [NSString stringWithFormat:
                    @"{\"ok\":true,\"result\":\"%@\"}", [result description]];
            }
            done = YES;
        }];

        // Spin run loop — completion handler fires on main thread
        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:timeout]) {
            if ([timeout timeIntervalSinceNow] <= 0) break;
        }

        if (!done) response = @"{\"ok\":false,\"error\":\"eval timeout\"}";
        result_json = response;
    });

    if (result_json) {
        send_json(fd, 200, [result_json UTF8String]);
    } else {
        send_json(fd, 500, "{\"ok\":false,\"error\":\"eval failed\"}");
    }
}
```

**Step 2: Add ui_get_active_webview accessor**

This is needed so `handle_eval` can call `evaluateJavaScript:` with a completion handler (unlike `ui_run_js` which is fire-and-forget).

In `ui.h`, inside `#ifdef SWIM_TEST`:

```c
void *ui_get_active_webview(SwimUI *ui);  // returns WKWebView* as void*
```

In `ui.m`, inside `#ifdef SWIM_TEST`:

```objc
void *ui_get_active_webview(SwimUI *ui) {
    if (ui->active_tab < 0 || ui->active_tab >= ui->tab_count) return NULL;
    return (__bridge void *)ui->tabs[ui->active_tab].webview;
}
```

**Step 3: Add route**

In the routing block, add before the 404 `else`:

```c
} else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/eval") == 0) {
    handle_eval(client_fd, &req, ctx);
```

**Step 4: Verify and test**

Run: `make test-ui`
Expected: Builds with no errors.

Manual test:
```bash
./swim-test --test-server 9111 &
sleep 2
curl -s -X POST localhost:9111/command -d '{"command":"open https://example.com"}'
sleep 2
# Get title
curl -s -X POST localhost:9111/eval -d '{"js":"document.title"}'
# Expected: {"ok":true,"result":"Example Domain"}
# Get number
curl -s -X POST localhost:9111/eval -d '{"js":"document.querySelectorAll(\"a\").length"}'
# Expected: {"ok":true,"result":1}
# Get object with json:true
curl -s -X POST localhost:9111/eval -d '{"js":"({a:1,b:2})","json":true}'
# Expected: {"ok":true,"result":"{\"a\":1,\"b\":2}"}
kill %1
```

**Step 5: Commit**

```bash
git add ui.h ui.m test_server.m
git commit -m "Add /eval endpoint for JavaScript evaluation with result return"
```

---

### Task 4: Batch Endpoint

Add `POST /batch` that accepts an array of steps, executes them sequentially, and returns an array of results. Refactor existing handlers to support both direct HTTP responses and internal result collection.

**Files:**
- Modify: `test_server.m` (refactor handlers + add `handle_batch` + route)

**Step 1: Add internal dispatch functions**

Each existing handler writes directly to a socket. For batch mode, we need versions that return an NSDictionary result instead. The cleanest approach: add internal `_result` functions that return NSDictionary, then have the HTTP handlers call those and serialize.

Add above the existing handlers (after `translate_key`):

```objc
// --- Internal handlers that return result dictionaries (for batch use) ---

static NSDictionary *do_action(NSDictionary *json, TestContext *ctx) {
    NSString *action = json[@"action"];
    if (!action) return @{@"ok": @NO, @"error": @"missing action"};

    NSNumber *count = json[@"count"];
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (count) ctx->mode->count = [count intValue];
        ctx->handle_action([action UTF8String], ctx->action_ctx);
        ctx->mode->count = 0;
    });
    return @{@"ok": @YES};
}

static NSDictionary *do_command(NSDictionary *json, TestContext *ctx) {
    NSString *command = json[@"command"];
    if (!command) return @{@"ok": @NO, @"error": @"missing command"};

    __block bool ok = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = registry_exec(ctx->commands, [command UTF8String]);
    });
    return @{@"ok": @(ok)};
}

static NSDictionary *do_key(NSDictionary *json, TestContext *ctx) {
    NSString *key = json[@"key"];
    if (!key) return @{@"ok": @NO, @"error": @"missing key"};

    const char *raw_key;
    unsigned int modifiers;
    translate_key([key UTF8String], &raw_key, &modifiers);
    NSNumber *mods = json[@"modifiers"];
    if (mods) modifiers |= [mods unsignedIntValue];

    __block bool consumed = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        consumed = mode_handle_key(ctx->mode, raw_key, modifiers);
    });
    return @{@"ok": @YES, @"consumed": @(consumed)};
}

static NSDictionary *do_screenshot(TestContext *ctx) {
    __block NSData *png = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        void *data = ui_screenshot(ctx->ui);
        if (data) png = (__bridge_transfer NSData *)data;
    });

    if (png) {
        NSString *b64 = [png base64EncodedStringWithOptions:0];
        return @{@"ok": @YES, @"content_type": @"image/png", @"base64": b64};
    }
    return @{@"ok": @NO, @"error": @"screenshot failed"};
}

static NSDictionary *do_state(TestContext *ctx) {
    __block NSDictionary *result = nil;
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

        result = @{
            @"ok": @YES,
            @"mode": [NSString stringWithUTF8String:mode_str],
            @"url": active ? [NSString stringWithUTF8String:active->url] : @"",
            @"title": active ? [NSString stringWithUTF8String:active->title] : @"",
            @"tab_count": @(ctx->browser->tab_count),
            @"active_tab": @(ctx->browser->active_tab),
            @"tabs": tabs,
            @"pending_keys": [NSString stringWithUTF8String:ctx->mode->pending_keys],
            @"count": @(ctx->mode->count),
        };
    });
    return result ?: @{@"ok": @NO, @"error": @"state failed"};
}

static NSDictionary *do_resize(NSDictionary *json, TestContext *ctx) {
    NSNumber *width = json[@"width"];
    NSNumber *height = json[@"height"];
    if (!width || !height) return @{@"ok": @NO, @"error": @"missing width/height"};

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSWindow *window = (__bridge NSWindow *)ui_get_window(ctx->ui);
        NSRect frame = [window frame];
        frame.size.width = [width doubleValue];
        frame.size.height = [height doubleValue];
        [window setFrame:frame display:YES animate:NO];
    });
    return @{@"ok": @YES};
}

static NSDictionary *do_wait(NSDictionary *json, TestContext *ctx) {
    NSNumber *timeout_ms = json[@"timeout"];
    double timeout_sec = timeout_ms ? [timeout_ms doubleValue] / 1000.0 : 10.0;
    if (timeout_sec > 30.0) timeout_sec = 30.0;
    if (timeout_sec < 0.1) timeout_sec = 0.1;

    __block bool loaded = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
        while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
            if (!ui_is_loading(ctx->ui)) { loaded = true; break; }
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!loaded) loaded = !ui_is_loading(ctx->ui);
    });
    return @{@"ok": @YES, @"loaded": @(loaded)};
}

static NSDictionary *do_eval(NSDictionary *json, TestContext *ctx) {
    NSString *js = json[@"js"];
    if (!js) return @{@"ok": @NO, @"error": @"missing js"};

    bool wrap_json = [json[@"json"] boolValue];
    NSString *eval_js = wrap_json ? [NSString stringWithFormat:@"JSON.stringify(%@)", js] : js;

    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

        __block NSDictionary *response = nil;
        __block BOOL done = NO;

        [wv evaluateJavaScript:eval_js completionHandler:^(id res, NSError *error) {
            if (error) {
                response = @{@"ok": @NO, @"error": error.localizedDescription ?: @"unknown"};
            } else if (res == nil || [res isKindOfClass:[NSNull class]]) {
                // NSNull and nil both become JSON null — build manually
                response = nil;  // handled below
            } else {
                // Let NSJSONSerialization handle all types
                response = @{@"ok": @YES, @"result": res};
            }
            done = YES;
        }];

        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:timeout]) {
            if ([timeout timeIntervalSinceNow] <= 0) break;
        }

        if (!done) {
            result = @{@"ok": @NO, @"error": @"eval timeout"};
        } else if (response) {
            result = response;
        } else {
            // null result — can't put nil in NSDictionary, use NSNull
            result = @{@"ok": @YES, @"result": [NSNull null]};
        }
    });
    return result ?: @{@"ok": @NO, @"error": @"eval failed"};
}

static NSDictionary *do_sleep_step(NSDictionary *json) {
    NSNumber *ms = json[@"ms"];
    double seconds = ms ? [ms doubleValue] / 1000.0 : 0.1;
    if (seconds > 10.0) seconds = 10.0;
    if (seconds < 0.01) seconds = 0.01;
    usleep((useconds_t)(seconds * 1000000));
    return @{@"ok": @YES};
}
```

**Step 2: Rewrite HTTP handlers to use internal functions**

Replace the existing `handle_action`, `handle_command`, `handle_key`, `handle_screenshot`, `handle_state`, `handle_resize`, `handle_wait`, `handle_eval` with thin wrappers:

```objc
// --- HTTP route handlers (thin wrappers around do_* functions) ---

static void handle_health(int fd) {
    send_json(fd, 200, "{\"ok\":true}");
}

static void send_dict(int fd, NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        send_response(fd, 200, "application/json", [data bytes], (int)[data length]);
    } else {
        send_json(fd, 500, "{\"error\":\"serialization failed\"}");
    }
}

static void handle_action(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_action(json, ctx));
}

static void handle_command(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_command(json, ctx));
}

static void handle_key(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_key(json, ctx));
}

static void handle_screenshot(int fd, TestContext *ctx) {
    // Direct endpoint still sends raw PNG
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
    send_dict(fd, do_state(ctx));
}

static void handle_resize(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_resize(json, ctx));
}

static void handle_wait(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_wait(json, ctx));
}

static void handle_eval(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_eval(json, ctx));
}
```

**Step 3: Add handle_batch**

```objc
static void handle_batch(int fd, HTTPRequest *req, TestContext *ctx) {
    if (!req->body || req->body_len <= 0) {
        send_json(fd, 400, "{\"error\":\"missing body\"}");
        return;
    }
    NSData *data = [NSData dataWithBytes:req->body length:req->body_len];
    NSArray *steps = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!steps || ![steps isKindOfClass:[NSArray class]]) {
        send_json(fd, 400, "{\"error\":\"body must be a JSON array\"}");
        return;
    }

    NSMutableArray *results = [NSMutableArray arrayWithCapacity:steps.count];

    for (NSDictionary *step in steps) {
        NSString *type = step[@"type"];
        if (!type) {
            [results addObject:@{@"ok": @NO, @"error": @"missing type"}];
            continue;
        }

        NSDictionary *result;
        if ([type isEqualToString:@"key"]) {
            result = do_key(step, ctx);
        } else if ([type isEqualToString:@"action"]) {
            result = do_action(step, ctx);
        } else if ([type isEqualToString:@"command"]) {
            result = do_command(step, ctx);
        } else if ([type isEqualToString:@"screenshot"]) {
            result = do_screenshot(ctx);
        } else if ([type isEqualToString:@"state"]) {
            result = do_state(ctx);
        } else if ([type isEqualToString:@"resize"]) {
            result = do_resize(step, ctx);
        } else if ([type isEqualToString:@"wait"]) {
            result = do_wait(step, ctx);
        } else if ([type isEqualToString:@"eval"]) {
            result = do_eval(step, ctx);
        } else if ([type isEqualToString:@"sleep"]) {
            result = do_sleep_step(step);
        } else {
            result = @{@"ok": @NO, @"error":
                [NSString stringWithFormat:@"unknown type: %@", type]};
        }

        [results addObject:result ?: @{@"ok": @NO, @"error": @"null result"}];
    }

    NSDictionary *response = @{@"ok": @YES, @"results": results};
    send_dict(fd, response);
}
```

**Step 4: Add route**

In the routing block, add before the 404 `else`:

```c
} else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/batch") == 0) {
    handle_batch(client_fd, &req, ctx);
```

**Step 5: Verify and test**

Run: `make test-ui`
Expected: Builds with no errors.

Manual test:
```bash
./swim-test --test-server 9111 &
sleep 2

# Batch: escape, navigate, wait, eval title, get state
curl -s -X POST localhost:9111/batch -d '[
  {"type":"key","key":"Escape"},
  {"type":"command","command":"open https://example.com"},
  {"type":"wait","timeout":5000},
  {"type":"eval","js":"document.title"},
  {"type":"state"}
]' | python3 -m json.tool

# Expected: {"ok":true,"results":[...5 results...]}
# Result[3] should have "result":"Example Domain"
# Result[4] should have url containing example.com

kill %1
```

**Step 6: Commit**

```bash
git add test_server.m
git commit -m "Add /batch endpoint and refactor handlers to internal do_* functions"
```

---

### Task 5: End-to-End Verification

Full rebuild and exercise every endpoint, both standalone and via batch.

**Step 1: Clean build**

Run: `make clean && make && make test-ui`
Expected: Both binaries built, no errors.

**Step 2: Verify release binary is clean**

Run: `nm swim | grep -ci test_server`
Expected: 0

**Step 3: Exercise all standalone endpoints**

```bash
./swim-test --test-server 9111 &
sleep 2

# Health
curl -s localhost:9111/health
# Expected: {"ok":true}

# Named keys
curl -s -X POST localhost:9111/key -d '{"key":"Escape"}'
curl -s -X POST localhost:9111/key -d '{"key":"j"}'
curl -s -X POST localhost:9111/key -d '{"key":"Ctrl-D"}'

# Navigate + wait
curl -s -X POST localhost:9111/command -d '{"command":"open https://example.com"}'
curl -s -X POST localhost:9111/wait -d '{"timeout":5000}'
# Expected: {"ok":true,"loaded":true}

# Eval
curl -s -X POST localhost:9111/eval -d '{"js":"document.title"}'
# Expected: {"ok":true,"result":"Example Domain"}

# State
curl -s localhost:9111/state | python3 -m json.tool

# Screenshot
curl -s localhost:9111/screenshot -o /tmp/test-v2.png && file /tmp/test-v2.png
# Expected: PNG image data

# Resize
curl -s -X POST localhost:9111/resize -d '{"width":800,"height":600}'

kill %1
```

**Step 4: Exercise batch**

```bash
./swim-test --test-server 9111 &
sleep 2

curl -s -X POST localhost:9111/batch -d '[
  {"type":"key","key":"Escape"},
  {"type":"command","command":"open https://example.com"},
  {"type":"wait","timeout":5000},
  {"type":"eval","js":"document.title"},
  {"type":"screenshot"},
  {"type":"action","action":"scroll-down","count":3},
  {"type":"sleep","ms":200},
  {"type":"state"}
]' | python3 -m json.tool

kill %1
```

**Step 5: Commit any fixes**

If any issues found during verification, fix and commit.
