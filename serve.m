#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>
#include <unistd.h>
#include "serve.h"

static int g_server_fd;

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

static void handle_eval(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_eval(json, ctx));
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
        } else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/eval") == 0) {
            handle_eval(client_fd, &req, ctx);
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
