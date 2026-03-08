#ifdef SWIM_TEST

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>
#include <unistd.h>
#include "test_server.h"

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

// --- Route handlers ---

static void handle_health(int fd) {
    send_json(fd, 200, "{\"ok\":true}");
}

static void handle_action(int fd, HTTPRequest *req, TestContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    NSString *action = json[@"action"];
    if (!action) { send_json(fd, 400, "{\"error\":\"missing action\"}"); return; }

    NSNumber *count = json[@"count"];

    dispatch_sync(dispatch_get_main_queue(), ^{
        if (count) ctx->mode->count = [count intValue];
        ctx->handle_action([action UTF8String], ctx->action_ctx);
        ctx->mode->count = 0;
    });

    send_json(fd, 200, "{\"ok\":true}");
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

#endif // SWIM_TEST
