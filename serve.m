#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>
#include <unistd.h>
#include "serve.h"

static int g_server_fd;

static const char *kExtractJS =
#include "extract_js.inc"
;

static const char *kInteractJS =
#include "interact_js.inc"
;

// --- HTTP helpers ---

static void send_response(int fd, int status, const char *content_type,
                          const void *body, int body_len) {
    const char *status_text = (status == 200) ? "OK" :
                              (status == 404) ? "Not Found" :
                              (status == 500) ? "Internal Server Error" : "Bad Request";
    char header[512];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n",
        status, status_text, content_type, body_len);
    const char *p = header;
    int remaining = hlen;
    while (remaining > 0) {
        ssize_t n = write(fd, p, remaining);
        if (n <= 0) return;
        p += n;
        remaining -= n;
    }
    const char *bp = body;
    remaining = body_len;
    while (remaining > 0) {
        ssize_t n = write(fd, bp, remaining);
        if (n <= 0) return;
        bp += n;
        remaining -= n;
    }
}

static void send_json(int fd, int status, const char *json) {
    send_response(fd, status, "application/json", json, (int)strlen(json));
}

static void send_dict(int fd, NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) {
        send_response(fd, 200, "application/json", [data bytes], (int)[data length]);
    } else {
        send_json(fd, 500, "{\"error\":\"serialization failed\"}");
    }
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
    while (total < (int)sizeof(buf) - 1) {
        int n = (int)read(fd, buf + total, sizeof(buf) - 1 - total);
        if (n <= 0) return false;
        total += n;
        buf[total] = '\0';
        if (strstr(buf, "\r\n\r\n")) break;
    }

    sscanf(buf, "%7s %255s", req->method, req->path);

    char *body_start = strstr(buf, "\r\n\r\n");
    if (!body_start) return false;
    body_start += 4;

    int content_length = 0;
    char *cl = strcasestr(buf, "Content-Length:");
    if (cl) content_length = atoi(cl + 15);

    int body_have = total - (int)(body_start - buf);

    if (content_length > 1048576) return false;  // 1 MB max body

    if (content_length > 0) {
        req->body = malloc(content_length + 1);
        memcpy(req->body, body_start, body_have);
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

// --- JSON helpers ---

static NSDictionary *parse_json_body(const char *body, int len) {
    if (!body || len <= 0) return nil;
    NSData *data = [NSData dataWithBytes:body length:len];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

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

    // Ctrl combos
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

static bool translate_key(const char *name, const char **out_key, unsigned int *out_mods) {
    for (int i = 0; key_map[i].name; i++) {
        if (strcmp(name, key_map[i].name) == 0) {
            *out_key = key_map[i].raw;
            *out_mods = key_map[i].modifiers;
            return true;
        }
    }
    *out_key = name;
    *out_mods = 0;
    return true;
}

// --- Internal handlers that return result dictionaries (for batch use) ---

static NSDictionary *do_action(NSDictionary *json, ServeContext *ctx) {
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

static NSDictionary *do_command(NSDictionary *json, ServeContext *ctx) {
    NSString *command = json[@"command"];
    if (!command) return @{@"ok": @NO, @"error": @"missing command"};

    __block bool ok = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = registry_exec(ctx->commands, [command UTF8String]);
    });
    return @{@"ok": @(ok)};
}

static NSDictionary *do_key(NSDictionary *json, ServeContext *ctx) {
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

static NSDictionary *do_screenshot(ServeContext *ctx) {
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

static NSDictionary *do_state(ServeContext *ctx) {
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

static NSDictionary *do_resize(NSDictionary *json, ServeContext *ctx) {
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

static NSDictionary *do_wait(NSDictionary *json, ServeContext *ctx) {
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

static NSDictionary *do_wait_for(NSDictionary *json, ServeContext *ctx) {
    NSString *selector = json[@"selector"];
    NSString *url_contains = json[@"url_contains"];
    if (!selector && !url_contains)
        return @{@"ok": @NO, @"error": @"missing selector or url_contains"};

    NSNumber *timeout_ms = json[@"timeout"];
    double timeout_sec = timeout_ms ? [timeout_ms doubleValue] / 1000.0 : 10.0;
    if (timeout_sec > 30.0) timeout_sec = 30.0;
    if (timeout_sec < 0.1) timeout_sec = 0.1;

    NSString *js;
    if (selector) {
        NSString *escapedSel = [selector stringByReplacingOccurrencesOfString:@"'"
                                                                  withString:@"\\'"];
        js = [NSString stringWithFormat:
            @"!!document.querySelector('%@')", escapedSel];
    } else {
        NSString *escapedUrl = [url_contains stringByReplacingOccurrencesOfString:@"'"
                                                                      withString:@"\\'"];
        js = [NSString stringWithFormat:
            @"location.href.indexOf('%@')!==-1", escapedUrl];
    }

    __block bool found = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) return;

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
        while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
            __block BOOL done = NO;
            __block BOOL exists = NO;

            [wv evaluateJavaScript:js completionHandler:^(id res, NSError *error) {
                if (!error && [res isKindOfClass:[NSNumber class]]) {
                    exists = [res boolValue];
                }
                done = YES;
            }];

            NSDate *pollEnd = [NSDate dateWithTimeIntervalSinceNow:0.2];
            while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                     beforeDate:pollEnd]) {
                if ([pollEnd timeIntervalSinceNow] <= 0) break;
            }

            if (exists) { found = true; break; }

            // Sleep 100ms between polls
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    });
    return @{@"ok": @YES, @"found": @(found)};
}

static NSDictionary *do_eval(NSDictionary *json, ServeContext *ctx) {
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
            result = @{@"ok": @YES, @"result": [NSNull null]};
        }
    });
    return result ?: @{@"ok": @NO, @"error": @"eval failed"};
}

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

static NSDictionary *do_interact(ServeContext *ctx) {
    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

        __block NSDictionary *response = nil;
        __block BOOL done = NO;

        NSString *js = [NSString stringWithUTF8String:kInteractJS];
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

        if (!done) result = @{@"ok": @NO, @"error": @"interact timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"interact failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"interact failed"};
}

static NSDictionary *do_fill(NSDictionary *json, ServeContext *ctx) {
    NSArray *fields = json[@"fields"];
    if (!fields || ![fields isKindOfClass:[NSArray class]] || fields.count == 0) {
        // Single-field shorthand: {selector, value}
        NSString *selector = json[@"selector"];
        NSString *value = json[@"value"];
        if (!selector) return @{@"ok": @NO, @"error": @"missing selector or fields array"};
        fields = @[@{@"selector": selector, @"value": value ?: @""}];
    }

    // Build JS that fills all fields
    NSMutableString *js = [NSMutableString stringWithString:@"(function(){var results=[];"];

    for (NSDictionary *field in fields) {
        NSString *sel = field[@"selector"];
        if (!sel) continue;

        NSString *escapedSel = [sel stringByReplacingOccurrencesOfString:@"\\"
                                                             withString:@"\\\\"];
        escapedSel = [escapedSel stringByReplacingOccurrencesOfString:@"'"
                                                           withString:@"\\'"];
        NSString *value = [field[@"value"] description] ?: @"";
        NSString *escapedVal = [value stringByReplacingOccurrencesOfString:@"\\"
                                                               withString:@"\\\\"];
        escapedVal = [escapedVal stringByReplacingOccurrencesOfString:@"'"
                                                          withString:@"\\'"];
        escapedVal = [escapedVal stringByReplacingOccurrencesOfString:@"\n"
                                                          withString:@"\\n"];

        [js appendFormat:
            @"(function(){"
            "var el=document.querySelector('%@');"
            "if(!el){results.push({selector:'%@',ok:false,error:'not found'});return}"
            "if(el.tagName==='SELECT'){"
            "  el.value='%@';"
            "  el.dispatchEvent(new Event('change',{bubbles:true}));"
            "  results.push({selector:'%@',ok:true})"
            "}"
            "else if(el.type==='checkbox'||el.type==='radio'){"
            "  var want=('%@'==='true'||'%@'==='1'||'%@'==='on');"
            "  if(el.checked!==want){el.click()}"
            "  results.push({selector:'%@',ok:true})"
            "}"
            "else{"
            "  var proto=el.tagName==='TEXTAREA'"
            "    ?window.HTMLTextAreaElement.prototype"
            "    :window.HTMLInputElement.prototype;"
            "  var desc=Object.getOwnPropertyDescriptor(proto,'value');"
            "  if(desc&&desc.set)desc.set.call(el,'%@');"
            "  else el.value='%@';"
            "  el.dispatchEvent(new Event('input',{bubbles:true}));"
            "  el.dispatchEvent(new Event('change',{bubbles:true}));"
            "  results.push({selector:'%@',ok:true})"
            "}"
            "})();",
            escapedSel, escapedSel,
            escapedVal, escapedSel,
            escapedVal, escapedVal, escapedVal, escapedSel,
            escapedVal, escapedVal, escapedSel
        ];
    }

    [js appendString:@"return JSON.stringify({ok:true,results:results})})()"];

    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

        __block NSDictionary *response = nil;
        __block BOOL done = NO;

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

        if (!done) result = @{@"ok": @NO, @"error": @"fill timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"fill failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"fill failed"};
}

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

// --- Feature: /query — read element text, attributes, visibility ---

static NSDictionary *do_query(NSDictionary *json, ServeContext *ctx) {
    NSString *selector = json[@"selector"];
    if (!selector) return @{@"ok": @NO, @"error": @"missing selector"};

    NSString *attribute = json[@"attribute"];
    NSNumber *allFlag = json[@"all"];
    BOOL queryAll = allFlag && [allFlag boolValue];

    NSString *escapedSel = [selector stringByReplacingOccurrencesOfString:@"\\"
                                                              withString:@"\\\\"];
    escapedSel = [escapedSel stringByReplacingOccurrencesOfString:@"'"
                                                       withString:@"\\'"];

    NSMutableString *js = [NSMutableString string];
    [js appendString:@"(function(){"];

    if (queryAll) {
        [js appendFormat:
            @"var els=document.querySelectorAll('%@');"
            "if(!els.length)return JSON.stringify({ok:true,found:false,results:[]});"
            "var results=[];var max=20;"
            "for(var i=0;i<els.length&&i<max;i++){var el=els[i];",
            escapedSel];
    } else {
        [js appendFormat:
            @"var el=document.querySelector('%@');"
            "if(!el)return JSON.stringify({ok:true,found:false});",
            escapedSel];
    }

    // Shared element info extraction
    NSString *extractInfo;
    if (attribute) {
        NSString *escapedAttr = [attribute stringByReplacingOccurrencesOfString:@"'"
                                                                    withString:@"\\'"];
        extractInfo = [NSString stringWithFormat:
            @"var val=el.getAttribute('%@');"
            "var info={tag:el.tagName.toLowerCase(),value:val};", escapedAttr];
    } else {
        extractInfo =
            @"var r=el.getBoundingClientRect();"
            "var s=window.getComputedStyle(el);"
            "var vis=s.display!=='none'&&s.visibility!=='hidden'&&r.width>0&&r.height>0;"
            "var attrs={};"
            "for(var j=0;j<el.attributes.length&&j<30;j++){"
            "  attrs[el.attributes[j].name]=el.attributes[j].value.substring(0,500)}"
            "var info={"
            "  tag:el.tagName.toLowerCase(),"
            "  text:el.textContent.trim().substring(0,2000),"
            "  visible:vis,"
            "  attributes:attrs,"
            "  rect:{x:Math.round(r.x),y:Math.round(r.y),"
            "        width:Math.round(r.width),height:Math.round(r.height)}"
            "};";
    }
    [js appendString:extractInfo];

    if (queryAll) {
        [js appendString:@"results.push(info)}"];
        [js appendString:
            @"return JSON.stringify({ok:true,found:true,count:els.length,results:results})"];
    } else {
        [js appendString:
            @"info.ok=true;info.found=true;"
            "return JSON.stringify(info)"];
    }

    [js appendString:@"})()"];

    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

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

        if (!done) result = @{@"ok": @NO, @"error": @"query timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"query failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"query failed"};
}

// --- Feature: /wait_for with url_contains for navigation wait ---
// (Handled by extending do_wait_for — see modified version above)

// --- Feature: /tab — switch to tab by index ---

static NSDictionary *do_tab(NSDictionary *json, ServeContext *ctx) {
    NSNumber *index = json[@"index"];
    if (!index) return @{@"ok": @NO, @"error": @"missing index"};

    int idx = [index intValue];

    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (idx < 0 || idx >= ctx->browser->tab_count) {
            result = @{@"ok": @NO, @"error": @"index out of range",
                       @"tab_count": @(ctx->browser->tab_count)};
            return;
        }

        browser_set_active(ctx->browser, idx);
        ui_select_tab(ctx->ui, idx);

        Tab *t = browser_active(ctx->browser);
        if (t && t->lazy && t->url[0]) {
            t->lazy = false;
            ui_navigate(ctx->ui, t->url);
        }

        result = @{
            @"ok": @YES,
            @"active_tab": @(idx),
            @"url": [NSString stringWithUTF8String:t ? t->url : ""],
            @"title": [NSString stringWithUTF8String:t ? t->title : ""],
        };
    });
    return result ?: @{@"ok": @NO, @"error": @"tab switch failed"};
}

// --- Feature: /select — choose option by visible text ---

static NSDictionary *do_select(NSDictionary *json, ServeContext *ctx) {
    NSString *selector = json[@"selector"];
    if (!selector) return @{@"ok": @NO, @"error": @"missing selector"};

    NSString *text = json[@"text"];
    NSString *value = json[@"value"];
    if (!text && !value) return @{@"ok": @NO, @"error": @"missing text or value"};

    NSString *escapedSel = [selector stringByReplacingOccurrencesOfString:@"\\"
                                                              withString:@"\\\\"];
    escapedSel = [escapedSel stringByReplacingOccurrencesOfString:@"'"
                                                       withString:@"\\'"];

    NSMutableString *js = [NSMutableString stringWithString:
        @"(function(){"
        "var el=document.querySelector('"];
    [js appendString:escapedSel];
    [js appendString:@"');"];
    [js appendString:@"if(!el||el.tagName!=='SELECT')"
        "return JSON.stringify({ok:false,error:'not a select element'});"];

    if (text) {
        NSString *escapedText = [text stringByReplacingOccurrencesOfString:@"\\"
                                                               withString:@"\\\\"];
        escapedText = [escapedText stringByReplacingOccurrencesOfString:@"'"
                                                            withString:@"\\'"];
        [js appendFormat:
            @"for(var i=0;i<el.options.length;i++){"
            "  if(el.options[i].textContent.trim()==='%@'){"
            "    el.value=el.options[i].value;"
            "    el.dispatchEvent(new Event('change',{bubbles:true}));"
            "    return JSON.stringify({ok:true,selected_value:el.options[i].value,"
            "      selected_text:el.options[i].textContent.trim()})}}"
            "return JSON.stringify({ok:false,error:'option not found'})",
            escapedText];
    } else {
        NSString *escapedVal = [value stringByReplacingOccurrencesOfString:@"\\"
                                                               withString:@"\\\\"];
        escapedVal = [escapedVal stringByReplacingOccurrencesOfString:@"'"
                                                          withString:@"\\'"];
        [js appendFormat:
            @"el.value='%@';"
            "el.dispatchEvent(new Event('change',{bubbles:true}));"
            "var opt=el.options[el.selectedIndex];"
            "return JSON.stringify({ok:true,selected_value:el.value,"
            "  selected_text:opt?opt.textContent.trim():''})",
            escapedVal];
    }

    [js appendString:@"})()"];

    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

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

        if (!done) result = @{@"ok": @NO, @"error": @"select timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"select failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"select failed"};
}

static NSDictionary *do_sleep_step(NSDictionary *json) {
    NSNumber *ms = json[@"ms"];
    double seconds = ms ? [ms doubleValue] / 1000.0 : 0.1;
    if (seconds > 10.0) seconds = 10.0;
    if (seconds < 0.01) seconds = 0.01;
    usleep((useconds_t)(seconds * 1000000));
    return @{@"ok": @YES};
}

// --- HTTP route handlers (thin wrappers around do_* functions) ---

static void handle_health(int fd) {
    send_json(fd, 200, "{\"ok\":true}");
}

static void handle_action(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_action(json, ctx));
}

static void handle_command(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_command(json, ctx));
}

static void handle_key(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_key(json, ctx));
}

static void handle_screenshot(int fd, ServeContext *ctx) {
    // Direct endpoint still sends raw PNG (not base64)
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

static void handle_state(int fd, ServeContext *ctx) {
    send_dict(fd, do_state(ctx));
}

static void handle_resize(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_resize(json, ctx));
}

static void handle_wait(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_wait(json, ctx));
}

static void handle_wait_for(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_wait_for(json, ctx));
}

static void handle_extract(int fd, ServeContext *ctx) {
    send_dict(fd, do_extract(ctx));
}

static void handle_interact(int fd, ServeContext *ctx) {
    send_dict(fd, do_interact(ctx));
}

static void handle_eval(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_eval(json, ctx));
}

static void handle_fill(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_fill(json, ctx));
}

static void handle_click(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_click(json, ctx));
}

static void handle_query(int fd, HTTPRequest *req, ServeContext *ctx) {
    if (!req->body || req->body_len <= 0) {
        send_json(fd, 400, "{\"error\":\"missing body\"}");
        return;
    }
    NSData *data = [NSData dataWithBytes:req->body length:req->body_len];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    send_dict(fd, do_query(json, ctx));
}

static void handle_tab(int fd, HTTPRequest *req, ServeContext *ctx) {
    if (!req->body || req->body_len <= 0) {
        send_json(fd, 400, "{\"error\":\"missing body\"}");
        return;
    }
    NSData *data = [NSData dataWithBytes:req->body length:req->body_len];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    send_dict(fd, do_tab(json, ctx));
}

static void handle_select(int fd, HTTPRequest *req, ServeContext *ctx) {
    if (!req->body || req->body_len <= 0) {
        send_json(fd, 400, "{\"error\":\"missing body\"}");
        return;
    }
    NSData *data = [NSData dataWithBytes:req->body length:req->body_len];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    send_dict(fd, do_select(json, ctx));
}

static void handle_batch(int fd, HTTPRequest *req, ServeContext *ctx) {
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
        } else if ([type isEqualToString:@"wait_for"]) {
            result = do_wait_for(step, ctx);
        } else if ([type isEqualToString:@"eval"]) {
            result = do_eval(step, ctx);
        } else if ([type isEqualToString:@"extract"]) {
            result = do_extract(ctx);
        } else if ([type isEqualToString:@"interact"]) {
            result = do_interact(ctx);
        } else if ([type isEqualToString:@"fill"]) {
            result = do_fill(step, ctx);
        } else if ([type isEqualToString:@"click"]) {
            result = do_click(step, ctx);
        } else if ([type isEqualToString:@"query"]) {
            result = do_query(step, ctx);
        } else if ([type isEqualToString:@"tab"]) {
            result = do_tab(step, ctx);
        } else if ([type isEqualToString:@"select"]) {
            result = do_select(step, ctx);
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

// --- Server thread ---

static void *server_thread(void *arg) {
    ServeContext *ctx = (ServeContext *)arg;

    while (1) {
        int client_fd = accept(g_server_fd, NULL, NULL);
        if (client_fd < 0) continue;

        HTTPRequest req = {0};
        if (!parse_request(client_fd, &req)) {
            close(client_fd);
            continue;
        }

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
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/wait") == 0) {
            handle_wait(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/wait_for") == 0) {
            handle_wait_for(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/eval") == 0) {
            handle_eval(client_fd, &req, ctx);
        } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/extract") == 0) {
            handle_extract(client_fd, ctx);
        } else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/interact") == 0) {
            handle_interact(client_fd, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/fill") == 0) {
            handle_fill(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/click") == 0) {
            handle_click(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/query") == 0) {
            handle_query(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/tab") == 0) {
            handle_tab(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/select") == 0) {
            handle_select(client_fd, &req, ctx);
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/batch") == 0) {
            handle_batch(client_fd, &req, ctx);
        } else {
            send_json(client_fd, 404, "{\"error\":\"not found\"}");
        }

        free(req.body);
        close(client_fd);
    }
    return NULL;
}

// --- Public API ---

void serve_start(int port, ServeContext *ctx) {
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

    fprintf(stderr, "swim: serving on port %d\n", port);

    g_server_fd = fd;
    pthread_t tid;
    pthread_create(&tid, NULL, server_thread, ctx);
    pthread_detach(tid);
}
