#import <Cocoa/Cocoa.h>
#include "browser.h"
#include "input.h"
#include "commands.h"
#include "ui.h"
#include "storage.h"
#include "config.h"
#include "userscript.h"
#include "focus.h"
#include "serve.h"

// --- App State ---

typedef struct App {
    Browser browser;
    ModeManager mode;
    CommandRegistry commands;
    SwimUI *ui;
    Storage bookmarks;
    Storage history;
    Config config;
    char session_path[512];
    char config_path[512];
    UserScriptManager userscripts;
    char scripts_path[512];
    SwimTheme theme;
    char themes_path[512];
} App;

static App app;

// --- Helpers ---

static bool is_blocked_scheme(const char *url) {
    return strncasecmp(url, "javascript:", 11) == 0 ||
           strncasecmp(url, "data:", 5) == 0 ||
           strncasecmp(url, "file:", 5) == 0;
}

static void set_url_with_tls(const char *url) {
    if (url && strncmp(url, "https://", 8) == 0) {
        char display[2200];
        snprintf(display, sizeof(display), "\xF0\x9F\x94\x92 %s", url);  // lock emoji
        ui_set_url(app.ui, display);
    } else {
        ui_set_url(app.ui, url ? url : "");
    }
}

// Expand a search template, replacing %s with the query
static void expand_search(const char *tmpl, const char *query, char *out, int out_size) {
    const char *pct = strstr(tmpl, "%s");
    if (pct) {
        int prefix_len = (int)(pct - tmpl);
        snprintf(out, out_size, "%.*s%s%s", prefix_len, tmpl, query, pct + 2);
    } else {
        snprintf(out, out_size, "%s%s", tmpl, query);
    }
}

static void open_url_in_active_tab(const char *raw) {
    if (!raw || !raw[0]) return;

    // Block dangerous URL schemes
    if (is_blocked_scheme(raw)) {
        ui_set_status_message(app.ui, "Blocked: unsafe URL scheme");
        return;
    }

    // Check for search engine shortcut prefix (e.g., "g foo bar")
    const char *space = strchr(raw, ' ');
    if (space) {
        int prefix_len = (int)(space - raw);
        for (int i = 0; i < app.config.search_shortcut_count; i++) {
            if ((int)strlen(app.config.search_shortcuts[i].prefix) == prefix_len &&
                strncmp(raw, app.config.search_shortcuts[i].prefix, prefix_len) == 0) {
                char search_url[4096];
                expand_search(app.config.search_shortcuts[i].url_template,
                    space + 1, search_url, sizeof(search_url));
                if (is_blocked_scheme(search_url)) {
                    ui_set_status_message(app.ui, "Blocked: unsafe URL scheme");
                    return;
                }
                ui_navigate(app.ui, search_url);
                return;
            }
        }
    }

    // If no dots or slashes, treat as default search
    if (!strchr(raw, '.') && !strchr(raw, '/') && strncmp(raw, "http", 4) != 0) {
        char search_url[4096];
        expand_search(app.config.search_engine, raw, search_url, sizeof(search_url));
        if (is_blocked_scheme(search_url)) {
            ui_set_status_message(app.ui, "Blocked: unsafe URL scheme");
            return;
        }
        ui_navigate(app.ui, search_url);
    } else {
        ui_navigate(app.ui, raw);
    }
}

static void create_tab_ex(const char *url, bool private_tab) {
    int tab_id = browser_add_tab(&app.browser, url ? url : "");
    ui_add_tab(app.ui, url, tab_id, private_tab);

    Tab *t = browser_active(&app.browser);
    if (t && t->url[0]) {
        set_url_with_tls(t->url);
    } else {
        ui_set_url(app.ui, "");
    }
}

static void create_tab(const char *url) {
    create_tab_ex(url, false);
}

static void app_set_mode(Mode m) {
    mode_set(&app.mode, m);
    ui_set_mode(app.ui, m);
}

static void sync_tab_display(void) {
    Tab *t = browser_active(&app.browser);
    if (t) {
        set_url_with_tls(t->url);
    } else {
        ui_set_url(app.ui, "");
    }
}

static int collect_tab_urls(const char **urls, int max) {
    int count = 0;
    for (int i = 0; i < app.browser.tab_count && count < max; i++) {
        if (app.browser.tabs[i].url[0] &&
            !ui_tab_is_private(app.ui, app.browser.tabs[i].id))
            urls[count++] = app.browser.tabs[i].url;
    }
    return count;
}

static void close_tab_at(int index) {
    bool is_private = ui_tab_is_private(app.ui, app.browser.tabs[index].id);
    browser_close_tab(&app.browser, index);
    if (is_private && app.browser.closed_count > 0) {
        free(app.browser.closed_urls[--app.browser.closed_count]);
    }
    ui_close_tab(app.ui, index);
}

static void switch_to_tab(int index) {
    browser_set_active(&app.browser, index);
    ui_select_tab(app.ui, index);
    Tab *t = browser_active(&app.browser);
    if (t && t->lazy && t->url[0]) {
        t->lazy = false;
        ui_navigate(app.ui, t->url);
    }
    sync_tab_display();
}

// --- Actions (from key bindings) ---

static int get_count(void) {
    return app.mode.count > 0 ? app.mode.count : 1;
}

// Focus overlay-aware scroll target
#define SCROLL_TARGET "var e=document.getElementById('swim-focus')||document.scrollingElement;"

static void scroll_js(const char *expr) {
    char js[256];
    snprintf(js, sizeof(js), SCROLL_TARGET "%s", expr);
    ui_run_js(app.ui, js);
}

static void handle_action(const char *action, void *ctx) {
    (void)ctx;
    int count = get_count();

    if (strcmp(action, "scroll-down") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollTop+=%d", 60 * count); scroll_js(e);
    } else if (strcmp(action, "scroll-up") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollTop-=%d", 60 * count); scroll_js(e);
    } else if (strcmp(action, "scroll-left") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollLeft-=%d", 60 * count); scroll_js(e);
    } else if (strcmp(action, "scroll-right") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollLeft+=%d", 60 * count); scroll_js(e);
    } else if (strcmp(action, "scroll-half-down") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollTop+=window.innerHeight/2*%d", count); scroll_js(e);
    } else if (strcmp(action, "scroll-half-up") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollTop-=window.innerHeight/2*%d", count); scroll_js(e);
    } else if (strcmp(action, "scroll-full-down") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollTop+=window.innerHeight*%d", count); scroll_js(e);
    } else if (strcmp(action, "scroll-full-up") == 0) {
        char e[64]; snprintf(e, sizeof(e), "e.scrollTop-=window.innerHeight*%d", count); scroll_js(e);
    } else if (strcmp(action, "scroll-top") == 0) {
        scroll_js("e.scrollTop=0");
    } else if (strcmp(action, "scroll-bottom") == 0) {
        scroll_js("e.scrollTop=e.scrollHeight");
    } else if (strcmp(action, "close-tab") == 0) {
        int idx = app.browser.active_tab;
        if (app.browser.tab_count <= 1) {
            ui_close(app.ui);
            return;
        }
        close_tab_at(idx);
        browser_set_active(&app.browser, app.browser.active_tab);
        sync_tab_display();
    } else if (strcmp(action, "undo-close-tab") == 0) {
        if (app.browser.closed_count > 0) {
            char *url = app.browser.closed_urls[--app.browser.closed_count];
            create_tab(url);
            open_url_in_active_tab(url);
            free(url);
        }
    } else if (strcmp(action, "prev-tab") == 0) {
        int idx = app.browser.active_tab - 1;
        if (idx < 0) idx = app.browser.tab_count - 1;
        switch_to_tab(idx);
    } else if (strcmp(action, "next-tab") == 0) {
        int idx = app.browser.active_tab + 1;
        if (idx >= app.browser.tab_count) idx = 0;
        switch_to_tab(idx);
    } else if (strcmp(action, "goto-tab") == 0) {
        int target;
        if (app.mode.count > 0) {
            target = app.mode.count - 1;  // 1-indexed to 0-indexed
            if (target >= app.browser.tab_count) target = app.browser.tab_count - 1;
            if (target < 0) target = 0;
        } else {
            target = app.browser.active_tab + 1;
            if (target >= app.browser.tab_count) target = 0;
        }
        switch_to_tab(target);
    } else if (strcmp(action, "move-tab-left") == 0 || strcmp(action, "move-tab-right") == 0) {
        int idx = app.browser.active_tab;
        int dir = (action[9] == 'l') ? -1 : 1;
        int target = (idx + dir + app.browser.tab_count) % app.browser.tab_count;
        browser_move_tab(&app.browser, idx, target);
        ui_move_tab(app.ui, idx, target);
        sync_tab_display();
    } else if (strcmp(action, "enter-command") == 0) {
        app_set_mode(MODE_COMMAND);
        ui_show_command_bar(app.ui, NULL, NULL, NULL);
    } else if (strcmp(action, "command-open") == 0) {
        Tab *t = browser_active(&app.browser);
        app_set_mode(MODE_COMMAND);
        ui_show_command_bar(app.ui, "open ", NULL, t ? t->url : NULL);
    } else if (strcmp(action, "command-open-current") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t) {
            app_set_mode(MODE_COMMAND);
            ui_show_command_bar(app.ui, "open ", t->url, NULL);
        }
    } else if (strcmp(action, "command-tabopen") == 0) {
        app_set_mode(MODE_COMMAND);
        ui_show_command_bar(app.ui, "tabopen ", NULL, NULL);
    } else if (strcmp(action, "reload") == 0) {
        ui_reload(app.ui);
    } else if (strcmp(action, "back") == 0) {
        ui_go_back(app.ui);
    } else if (strcmp(action, "forward") == 0) {
        ui_go_forward(app.ui);
    } else if (strcmp(action, "mode-normal") == 0) {
        app_set_mode(MODE_NORMAL);
        ui_hide_command_bar(app.ui);
        // Dismiss focus overlay if active, otherwise blur active element
        ui_run_js(app.ui,
            "var f=document.getElementById('swim-focus');"
            "if(f){f.remove();document.body.style.overflow='';}"
            "else{document.activeElement.blur()}");
    } else if (strcmp(action, "hint-follow") == 0 || strcmp(action, "hint-tab") == 0 || strcmp(action, "hint-yank") == 0) {
        int mode = action[5] == 'f' ? 0 : action[5] == 't' ? 1 : 2;
        app_set_mode(MODE_HINT);
        ui_show_hints(app.ui, mode);
    } else if (strcmp(action, "hint-filter") == 0) {
        ui_filter_hints(app.ui, app.mode.pending_keys);
    } else if (strcmp(action, "hint-cancel") == 0) {
        ui_cancel_hints(app.ui);
    } else if (strcmp(action, "find") == 0) {
        app_set_mode(MODE_COMMAND);
        ui_show_find_bar(app.ui);
    } else if (strcmp(action, "find-next") == 0) {
        ui_find_next(app.ui);
    } else if (strcmp(action, "find-prev") == 0) {
        ui_find_prev(app.ui);
    } else if (strcmp(action, "yank-url") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t && t->url[0]) {
            NSString *url = [NSString stringWithUTF8String:t->url];
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:url forType:NSPasteboardTypeString];
            ui_set_status_message(app.ui, "Yanked URL");
        }
    } else if (strcmp(action, "yank-pretty-url") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t && t->url[0]) {
            NSString *encoded = [NSString stringWithUTF8String:t->url];
            NSString *decoded = [encoded stringByRemovingPercentEncoding];
            if (!decoded) decoded = encoded;
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:decoded forType:NSPasteboardTypeString];
            ui_set_status_message(app.ui, "Yanked decoded URL");
        }
    } else if (strcmp(action, "paste-open") == 0) {
        NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        if (clip && clip.length > 0) {
            open_url_in_active_tab([clip UTF8String]);
        }
    } else if (strcmp(action, "paste-tabopen") == 0) {
        NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        if (clip && clip.length > 0) {
            create_tab(NULL);
            open_url_in_active_tab([clip UTF8String]);
        }
    } else if (strcmp(action, "command-tabopen-current") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t) {
            app_set_mode(MODE_COMMAND);
            ui_show_command_bar(app.ui, "tabopen ", t->url, NULL);
        }
    } else if (strcmp(action, "enter-passthrough") == 0) {
        app_set_mode(MODE_PASSTHROUGH);
    } else if (strcmp(action, "navigate-up") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t && t->url[0]) {
            NSString *urlStr = [NSString stringWithUTF8String:t->url];
            NSURL *url = [NSURL URLWithString:urlStr];
            if (url && url.path.length > 1) {
                NSURL *parent = [url URLByDeletingLastPathComponent];
                if (parent) {
                    ui_navigate(app.ui, [parent.absoluteString UTF8String]);
                }
            }
        }
    } else if (strcmp(action, "navigate-root") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t && t->url[0]) {
            NSString *urlStr = [NSString stringWithUTF8String:t->url];
            NSURL *url = [NSURL URLWithString:urlStr];
            if (url && url.scheme && url.host) {
                NSString *root = [NSString stringWithFormat:@"%@://%@", url.scheme, url.host];
                ui_navigate(app.ui, [root UTF8String]);
            }
        }
    }
}

// --- Commands (from command bar) ---

static void cmd_open(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0]) return;
    open_url_in_active_tab(args);
    Tab *t = browser_active(&app.browser);
    if (t) snprintf(t->url, sizeof(t->url), "%s", args);
}

static void cmd_tabopen(const char *args, void *ctx) {
    (void)ctx;
    if (args && args[0]) {
        create_tab(NULL);
        open_url_in_active_tab(args);
        Tab *t = browser_active(&app.browser);
        if (t) snprintf(t->url, sizeof(t->url), "%s", args);
    } else {
        create_tab(app.config.homepage);
    }
}

static void cmd_bookmark(const char *args, void *ctx) {
    (void)args; (void)ctx;
    Tab *t = browser_active(&app.browser);
    if (t && t->url[0]) {
        storage_add(&app.bookmarks, t->url, t->title);
        storage_save(&app.bookmarks);
    }
}

static void cmd_marks(const char *args, void *ctx) {
    (void)ctx;
    int results[20];
    int count = storage_search(&app.bookmarks, args ? args : "", results, 20);
    if (count > 0) {
        // Open the first match
        open_url_in_active_tab(app.bookmarks.entries[results[0]].url);
    }
}

static void cmd_history(const char *args, void *ctx) {
    (void)ctx;
    int results[20];
    int count = storage_search(&app.history, args ? args : "", results, 20);
    if (count > 0) {
        open_url_in_active_tab(app.history.entries[results[0]].url);
    }
}

static void cmd_set(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0]) return;

    // Split "key value"
    char key[64];
    int i = 0;
    while (args[i] && args[i] != ' ' && i < 63) {
        key[i] = args[i];
        i++;
    }
    key[i] = '\0';
    const char *value = args[i] ? args + i + 1 : "";

    if (!config_set(&app.config, key, value)) {
        char msg[128];
        snprintf(msg, sizeof(msg), "Invalid: %s = %s", key, value);
        ui_set_status_message(app.ui, msg);
        return;
    }

    // Apply live-reloadable settings
    if (strcmp(key, "tab_bar") == 0)
        ui_set_tab_bar_mode(app.ui, app.config.tab_bar);
    else if (strcmp(key, "status_bar") == 0)
        ui_set_status_bar_mode(app.ui, app.config.status_bar);
    else if (strcmp(key, "adblock") == 0)
        ui_set_adblock(app.ui, app.config.adblock_enabled);
    else if (strcmp(key, "dark_mode") == 0)
        ui_set_dark_mode(app.ui, app.config.dark_mode);

    // Persist to disk
    config_save(&app.config, app.config_path);

    char msg[128];
    snprintf(msg, sizeof(msg), "%s = %s", key, value);
    ui_set_status_message(app.ui, msg);
}

static void cmd_settings(const char *args, void *ctx) {
    (void)args; (void)ctx;
    char msg[512];
    snprintf(msg, sizeof(msg),
        "homepage=%s search_engine=%s restore_session=%s "
        "font_size=%d tab_bar=%s status_bar=%s theme=%s "
        "compact_titlebar=%s adblock=%s dark_mode=%s proxy=%s",
        app.config.homepage,
        app.config.search_engine,
        app.config.restore_session ? "true" : "false",
        app.config.font_size,
        app.config.tab_bar,
        app.config.status_bar,
        app.config.theme,
        app.config.compact_titlebar ? "true" : "false",
        app.config.adblock_enabled ? "true" : "false",
        app.config.dark_mode ? "true" : "false",
        app.config.proxy_type);
    ui_set_status_message(app.ui, msg);
}

static void cmd_help(const char *args, void *ctx) {
    (void)args; (void)ctx;
    // List all registered commands
    char msg[1024];
    int pos = 0;
    for (int i = 0; i < app.commands.count && pos < 1000; i++) {
        Command *c = &app.commands.commands[i];
        if (c->alias) {
            pos += snprintf(msg + pos, sizeof(msg) - pos, ":%s(%s) ", c->name, c->alias);
        } else {
            pos += snprintf(msg + pos, sizeof(msg) - pos, ":%s ", c->name);
        }
    }
    ui_set_status_message(app.ui, msg);
}

static void cmd_adblock(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0] || strcmp(args, "on") == 0) {
        ui_set_adblock(app.ui, true);
    } else if (strcmp(args, "off") == 0) {
        ui_set_adblock(app.ui, false);
    }
}

static void cmd_passthrough(const char *args, void *ctx) {
    (void)args; (void)ctx;
    app_set_mode(MODE_PASSTHROUGH);
}

static void cmd_private(const char *args, void *ctx) {
    (void)ctx;
    create_tab_ex(args && args[0] ? args : NULL, true);
    if (args && args[0]) {
        open_url_in_active_tab(args);
    }
    ui_set_status_message(app.ui, "Private tab");
}

static void cmd_darkmode(const char *args, void *ctx) {
    (void)ctx;
    if (args && strcmp(args, "off") == 0) {
        app.config.dark_mode = false;
    } else {
        app.config.dark_mode = !app.config.dark_mode;
    }
    ui_set_dark_mode(app.ui, app.config.dark_mode);
    ui_set_status_message(app.ui, app.config.dark_mode ? "Dark mode on" : "Dark mode off");
}

static void cmd_mute(const char *args, void *ctx) {
    (void)args; (void)ctx;
    ui_toggle_mute(app.ui);
}

static void cmd_devtools(const char *args, void *ctx) {
    (void)args; (void)ctx;
    ui_open_inspector(app.ui);
}

static void cmd_proxy(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0] || strcmp(args, "off") == 0) {
        snprintf(app.config.proxy_type, sizeof(app.config.proxy_type), "none");
        app.config.proxy_host[0] = '\0';
        app.config.proxy_port = 0;
        ui_set_proxy(app.ui, "none", NULL, 0);
        return;
    }

    // Parse: "http host:port" or "socks5 host:port"
    char type[16] = "";
    char hostport[256] = "";
    int i = 0;
    while (args[i] && args[i] != ' ' && i < 15) { type[i] = args[i]; i++; }
    type[i] = '\0';
    if (args[i] == ' ') {
        i++;
        int j = 0;
        while (args[i] && j < 255) { hostport[j++] = args[i++]; }
        hostport[j] = '\0';
    }

    if (!hostport[0]) {
        ui_set_status_message(app.ui, "Usage: proxy http|socks5 host:port");
        return;
    }

    // Split host:port
    char host[256] = "";
    int port = 0;
    char *colon = strrchr(hostport, ':');
    if (colon) {
        int hlen = (int)(colon - hostport);
        snprintf(host, sizeof(host), "%.*s", hlen, hostport);
        port = atoi(colon + 1);
    } else {
        snprintf(host, sizeof(host), "%s", hostport);
        port = (strcmp(type, "socks5") == 0) ? 1080 : 8080;
    }

    snprintf(app.config.proxy_type, sizeof(app.config.proxy_type), "%s", type);
    snprintf(app.config.proxy_host, sizeof(app.config.proxy_host), "%s", host);
    app.config.proxy_port = port;
    ui_set_proxy(app.ui, type, host, port);
}

static void cmd_focus(const char *args, void *ctx) {
    (void)args; (void)ctx;
    char *js = focus_build_js(&app.theme, app.scripts_path);
    if (!js) {
        ui_set_status_message(app.ui, "Failed to load focus mode");
        return;
    }
    ui_run_js(app.ui, js);
    free(js);
}

static void cmd_session(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0]) return;

    const char *home = getenv("HOME");
    if (!home) return;

    // Parse "save name" or "load name"
    char subcmd[32] = "";
    char name[128] = "";
    int i = 0;
    while (args[i] && args[i] != ' ' && i < 31) { subcmd[i] = args[i]; i++; }
    subcmd[i] = '\0';
    if (args[i] == ' ') {
        i++;
        int j = 0;
        while (args[i] && j < 127) { name[j++] = args[i++]; }
        name[j] = '\0';
    }

    if (!name[0]) {
        ui_set_status_message(app.ui, "Usage: session save|load <name>");
        return;
    }

    // Reject unsafe session names
    for (int k = 0; name[k]; k++) {
        char c = name[k];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_')) {
            ui_set_status_message(app.ui, "Session name: alphanumeric, - and _ only");
            return;
        }
    }

    char path[512];
    snprintf(path, sizeof(path), "%s/.config/swim/session-%s.json", home, name);

    if (strcmp(subcmd, "save") == 0) {
        const char *urls[128];
        int count = collect_tab_urls(urls, 128);
        session_save(path, urls, count);
        char msg[256];
        snprintf(msg, sizeof(msg), "Session '%s' saved (%d tabs)", name, count);
        ui_set_status_message(app.ui, msg);
    } else if (strcmp(subcmd, "load") == 0) {
        char session_urls[128][2048];
        int session_count = session_load(path, session_urls, 128);
        if (session_count > 0) {
            for (int k = 0; k < session_count; k++) {
                create_tab(session_urls[k]);
            }
            char msg[256];
            snprintf(msg, sizeof(msg), "Session '%s' loaded (%d tabs)", name, session_count);
            ui_set_status_message(app.ui, msg);
        } else {
            char msg[256];
            snprintf(msg, sizeof(msg), "Session '%s' not found", name);
            ui_set_status_message(app.ui, msg);
        }
    }
}

static void cmd_tabs(const char *args, void *ctx) {
    (void)args; (void)ctx;
    if (app.browser.tab_count == 0) return;

    char buf[2048] = {0};
    int pos = 0;
    for (int i = 0; i < app.browser.tab_count && pos < (int)sizeof(buf) - 100; i++) {
        Tab *t = &app.browser.tabs[i];
        const char *title = t->title[0] ? t->title : t->url;
        char short_title[30];
        snprintf(short_title, sizeof(short_title), "%s", title);

        if (i > 0) pos += snprintf(buf + pos, sizeof(buf) - pos, " | ");
        if (i == app.browser.active_tab) {
            pos += snprintf(buf + pos, sizeof(buf) - pos, "%d: *%s", i + 1, short_title);
        } else {
            pos += snprintf(buf + pos, sizeof(buf) - pos, "%d: %s", i + 1, short_title);
        }
    }
    ui_set_status_message(app.ui, buf);
}

static void cmd_tabclose(const char *args, void *ctx) {
    (void)ctx;
    int target;
    if (args && args[0]) {
        target = atoi(args) - 1;
    } else {
        target = app.browser.active_tab;
    }

    if (target < 0 || target >= app.browser.tab_count) {
        ui_set_status_message(app.ui, "Invalid tab number");
        return;
    }

    if (app.browser.tab_count <= 1) {
        ui_close(app.ui);
        return;
    }

    close_tab_at(target);
    browser_set_active(&app.browser, app.browser.active_tab);
    sync_tab_display();
}

static void cmd_tabonly(const char *args, void *ctx) {
    (void)args; (void)ctx;
    int keep = app.browser.active_tab;

    for (int i = app.browser.tab_count - 1; i >= 0; i--) {
        if (i == keep) continue;
        close_tab_at(i);
        if (i < keep) keep--;
    }
    browser_set_active(&app.browser, 0);
    sync_tab_display();
}

static void cmd_quit(const char *args, void *ctx) {
    (void)args; (void)ctx;
    ui_close(app.ui);
}

static void cmd_scripts(const char *args, void *ctx) {
    (void)ctx;
    if (args && strcmp(args, "reload") == 0) {
        userscript_free(&app.userscripts);
        int n = userscript_load_dir(&app.userscripts, app.scripts_path);
        char msg[128];
        snprintf(msg, sizeof(msg), "Reloaded %d userscript%s", n, n == 1 ? "" : "s");
        ui_set_status_message(app.ui, msg);
        return;
    }

    if (app.userscripts.count == 0) {
        ui_set_status_message(app.ui, "No userscripts loaded");
        return;
    }

    char buf[2048] = {0};
    int pos = 0;
    for (int i = 0; i < app.userscripts.count && pos < (int)sizeof(buf) - 100; i++) {
        UserScript *s = &app.userscripts.scripts[i];
        if (i > 0) pos += snprintf(buf + pos, sizeof(buf) - pos, " | ");
        pos += snprintf(buf + pos, sizeof(buf) - pos, "%s", s->name);
        if (s->match_count > 0) {
            pos += snprintf(buf + pos, sizeof(buf) - pos, " [%s]", s->match[0]);
        }
    }
    ui_set_status_message(app.ui, buf);
}

// --- UI Callbacks ---

static void substitute_vars(const char *input, char *output, int output_size) {
    int oi = 0;
    int remaining;

    // Safe append via snprintf — clamp oi to prevent overflow
    #define SUBST_APPEND(fmt, val) do { \
        remaining = output_size - oi; \
        if (remaining > 1) { \
            int n = snprintf(&output[oi], remaining, fmt, val); \
            oi += (n < remaining) ? n : (remaining - 1); \
        } \
    } while(0)

    for (int i = 0; input[i] && oi < output_size - 1; i++) {
        if (input[i] == '{') {
            if (strncmp(&input[i], "{url}", 5) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) SUBST_APPEND("%s", t->url);
                i += 4; continue;
            } else if (strncmp(&input[i], "{title}", 7) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) SUBST_APPEND("%s", t->title);
                i += 6; continue;
            } else if (strncmp(&input[i], "{clipboard}", 11) == 0) {
                NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
                if (clip) SUBST_APPEND("%s", [clip UTF8String]);
                i += 10; continue;
            } else if (strncmp(&input[i], "{url:host}", 10) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) {
                    NSString *s = [NSString stringWithUTF8String:t->url];
                    NSURL *u = [NSURL URLWithString:s];
                    if (u.host) SUBST_APPEND("%s", [u.host UTF8String]);
                }
                i += 9; continue;
            } else if (strncmp(&input[i], "{url:path}", 10) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) {
                    NSString *s = [NSString stringWithUTF8String:t->url];
                    NSURL *u = [NSURL URLWithString:s];
                    if (u.path) SUBST_APPEND("%s", [u.path UTF8String]);
                }
                i += 9; continue;
            }
        }
        output[oi++] = input[i];
    }
    output[oi] = '\0';

    #undef SUBST_APPEND
}

static void on_command_submit(const char *text, void *ctx) {
    (void)ctx;
    app_set_mode(MODE_NORMAL);
    ui_hide_command_bar(app.ui);

    // Variable substitution
    char expanded[4096];
    substitute_vars(text, expanded, sizeof(expanded));

    if (!registry_exec(&app.commands, expanded)) {
        char msg[256];
        snprintf(msg, sizeof(msg), "Unknown command: %s", expanded);
        ui_set_status_message(app.ui, msg);
    }
}

static void on_command_cancel(void *ctx) {
    (void)ctx;
    app_set_mode(MODE_NORMAL);
    ui_hide_command_bar(app.ui);
}

static void on_url_changed(const char *url, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_url(&app.browser, tab_id, url);
    Tab *t = browser_active(&app.browser);
    if (t && t->id == tab_id) {
        set_url_with_tls(url);
    }
    // Record in history (skip private tabs)
    if (url && strncmp(url, "about:", 6) != 0 && !ui_tab_is_private(app.ui, tab_id)) {
        int idx = browser_find_tab(&app.browser, tab_id);
        const char *title = (idx >= 0) ? app.browser.tabs[idx].title : "";
        storage_add(&app.history, url, title);
        storage_save(&app.history);
    }
}

static void on_title_changed(const char *title, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_title(&app.browser, tab_id, title);
    ui_update_tab_title(app.ui, tab_id, title);

    // Update window title to active tab
    Tab *t = browser_active(&app.browser);
    if (t && t->id == tab_id) {
        ui_set_window_title(app.ui, t->title);
    }
}

static void on_load_changed(bool loading, double progress, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_loading(&app.browser, tab_id, loading, progress);
    ui_set_progress(app.ui, progress);
}

static void on_nav_error(const char *error, int tab_id, void *ctx) {
    (void)ctx;
    if (error) {
        browser_tab_set_error(&app.browser, tab_id, error);
    } else {
        browser_tab_clear_error(&app.browser, tab_id);
    }
}

static void on_focus_changed(bool focused, void *ctx) {
    (void)ctx;
    app_set_mode(focused ? MODE_INSERT : MODE_NORMAL);
}

static void on_hints_done(void *ctx) {
    (void)ctx;
    app_set_mode(MODE_NORMAL);
}

static char url_complete_buf[2048];
static int url_complete_idx;

static const char *on_command_complete(const char *prefix, const char *cmd_prefix, void *ctx) {
    (void)ctx;

    // URL completion for open/tabopen commands
    if (cmd_prefix[0]) {
        int results[64];
        int count = storage_search(&app.history, prefix, results, 64);
        int bm_results[64];
        int bm_count = storage_search(&app.bookmarks, prefix, bm_results, 64);

        // On first tab or new prefix, reset index
        static char last_prefix[256];
        if (strcmp(prefix, last_prefix) != 0) {
            url_complete_idx = 0;
            snprintf(last_prefix, sizeof(last_prefix), "%s", prefix);
        } else {
            url_complete_idx++;
        }

        // Cycle through bookmarks first, then history
        if (url_complete_idx < bm_count) {
            snprintf(url_complete_buf, sizeof(url_complete_buf), "%s",
                app.bookmarks.entries[bm_results[url_complete_idx]].url);
            return url_complete_buf;
        }
        int hist_idx = url_complete_idx - bm_count;
        if (hist_idx < count) {
            snprintf(url_complete_buf, sizeof(url_complete_buf), "%s",
                app.history.entries[results[hist_idx]].url);
            return url_complete_buf;
        }
        // Wrap around
        url_complete_idx = -1;  // will increment to 0 next time
        return NULL;
    }

    // Command name completion
    return registry_complete(&app.commands, prefix);
}

static void on_tab_selected(int index, void *ctx) {
    (void)ctx;
    switch_to_tab(index);
}

// --- Main ---

int main(int argc, const char *argv[]) {

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Minimal menu bar — Edit menu enables Cmd-C/V/A/X in WKWebView text fields
        NSMenu *menuBar = [[NSMenu alloc] init];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"swim"];
        [appMenu addItemWithTitle:@"Quit swim" action:@selector(terminate:) keyEquivalent:@"q"];
        appMenuItem.submenu = appMenu;
        [menuBar addItem:appMenuItem];

        NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        editMenuItem.submenu = editMenu;
        [menuBar addItem:editMenuItem];
        [NSApp setMainMenu:menuBar];

        const char *serve_addr = NULL;
        bool serve = false;
        const char *profile = NULL;
        const char *app_url = NULL;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--serve") == 0) {
                serve = true;
                if (i + 1 < argc) {
                    char c = argv[i + 1][0];
                    if (c == '/' || c == '.' || (c >= '0' && c <= '9'))
                        serve_addr = argv[++i];
                }
            } else if (strcmp(argv[i], "--app") == 0 && i + 1 < argc) {
                app_url = argv[++i];
            } else if (strcmp(argv[i], "--profile") == 0 && i + 1 < argc) {
                profile = argv[++i];
            }
        }

        // Ensure config dir exists
        storage_ensure_dir();

        // Load config
        config_init(&app.config);
        const char *home = getenv("HOME");
        if (!home) home = ".";
        {
            char profiles_dir[512];
            snprintf(profiles_dir, sizeof(profiles_dir),
                "%s/.config/swim/profiles", home);
            config_create_default_profiles(profiles_dir);
        }
        snprintf(app.config_path, sizeof(app.config_path),
            "%s/.config/swim/config.toml", home);
        config_load(&app.config, app.config_path);

        // Apply profile overlay
        if (profile) {
            char profile_path[512];
            snprintf(profile_path, sizeof(profile_path),
                "%s/.config/swim/profiles/%s.toml", home, profile);
            config_load(&app.config, profile_path);
        }

        // Init storage
        char bm_path[512], hist_path[512];
        snprintf(bm_path, sizeof(bm_path), "%s/.config/swim/bookmarks.json", home);
        snprintf(hist_path, sizeof(hist_path), "%s/.config/swim/history.json", home);
        storage_init(&app.bookmarks, bm_path);
        storage_init(&app.history, hist_path);
        storage_load(&app.bookmarks);
        storage_load(&app.history);
        snprintf(app.session_path, sizeof(app.session_path),
            "%s/.config/swim/session.json", home);

        // Userscripts
        snprintf(app.scripts_path, sizeof(app.scripts_path),
            "%s/.config/swim/scripts", home);
        userscript_create_defaults(app.scripts_path);
        focus_create_default(app.scripts_path);
        userscript_init(&app.userscripts);
        userscript_load_dir(&app.userscripts, app.scripts_path);

        // Theme
        snprintf(app.themes_path, sizeof(app.themes_path),
            "%s/.config/swim/themes", home);
        theme_create_defaults(app.themes_path);
        theme_init_defaults(&app.theme);
        if (app.config.theme[0] && strcmp(app.config.theme, "default") != 0
            && strcmp(app.config.theme, "dark") != 0) {
            char theme_path[1024];
            snprintf(theme_path, sizeof(theme_path), "%s/%s.theme",
                app.themes_path, app.config.theme);
            if (!theme_load(&app.theme, theme_path)) {
                fprintf(stderr, "swim: theme '%s' not found\n", app.config.theme);
            }
        }

        // App mode: override config to hide all chrome
        if (app_url) {
            snprintf(app.config.tab_bar, sizeof(app.config.tab_bar), "never");
            snprintf(app.config.status_bar, sizeof(app.config.status_bar), "never");
        }

        // Init pure C state
        browser_init(&app.browser);
        mode_init(&app.mode, handle_action, &app);

        // Apply custom keybindings from config (skip in app mode)
        if (!app_url) {
            for (int i = 0; i < app.config.key_binding_count; i++) {
                keytrie_bind(&app.mode.normal_keys,
                    app.config.key_bindings[i].keys,
                    app.config.key_bindings[i].action);
            }
        }

        registry_init(&app.commands, &app);
        registry_add(&app.commands, "open", "o", cmd_open, "Navigate to URL");
        registry_add(&app.commands, "tabopen", "to", cmd_tabopen, "Open in new tab");
        registry_add(&app.commands, "quit", "q", cmd_quit, "Quit swim");
        registry_add(&app.commands, "adblock", NULL, cmd_adblock, "Toggle adblock on/off");
        registry_add(&app.commands, "bookmark", "bm", cmd_bookmark, "Bookmark current page");
        registry_add(&app.commands, "marks", NULL, cmd_marks, "Search bookmarks");
        registry_add(&app.commands, "history", NULL, cmd_history, "Search history");
        registry_add(&app.commands, "set", NULL, cmd_set, "Set config value");
        registry_add(&app.commands, "settings", NULL, cmd_settings, "Show current settings");
        registry_add(&app.commands, "passthrough", NULL, cmd_passthrough, "Enter passthrough mode");
        registry_add(&app.commands, "focus", NULL, cmd_focus, "Reader mode");
        registry_add(&app.commands, "session", NULL, cmd_session, "Save/load named sessions");
        registry_add(&app.commands, "tabs", NULL, cmd_tabs, "List open tabs");
        registry_add(&app.commands, "tabclose", "tc", cmd_tabclose, "Close tab by number");
        registry_add(&app.commands, "tabonly", NULL, cmd_tabonly, "Close all tabs except current");
        registry_add(&app.commands, "scripts", NULL, cmd_scripts, "List/reload userscripts");
        registry_add(&app.commands, "help", "h", cmd_help, "List all commands");
        registry_add(&app.commands, "private", "p", cmd_private, "Open private tab");
        registry_add(&app.commands, "darkmode", "dm", cmd_darkmode, "Toggle dark mode");
        registry_add(&app.commands, "mute", NULL, cmd_mute, "Toggle tab audio mute");
        registry_add(&app.commands, "devtools", NULL, cmd_devtools, "Open web inspector");
        registry_add(&app.commands, "proxy", NULL, cmd_proxy, "Set proxy (http|socks5 host:port)");
        // Create UI
        UICallbacks callbacks = {
            .on_command_submit = on_command_submit,
            .on_command_cancel = on_command_cancel,
            .on_url_changed = on_url_changed,
            .on_title_changed = on_title_changed,
            .on_load_changed = on_load_changed,
            .on_nav_error = on_nav_error,
            .on_focus_changed = on_focus_changed,
            .on_hints_done = on_hints_done,
            .on_tab_selected = on_tab_selected,
            .on_command_complete = on_command_complete,
            .ctx = &app,
        };
        app.ui = ui_create(callbacks, app.config.compact_titlebar, app.config.tab_bar, app.config.status_bar, &app.theme);

        // Load adblock rules
        if (app.config.adblock_enabled) {
            ui_load_blocklist(app.ui);
        }

        // Apply dark mode
        if (app.config.dark_mode) {
            ui_set_dark_mode(app.ui, true);
        }

        // Apply proxy if configured
        if (strcmp(app.config.proxy_type, "none") != 0 && app.config.proxy_host[0]) {
            ui_set_proxy(app.ui, app.config.proxy_type,
                app.config.proxy_host, app.config.proxy_port);
        }

        // Wire userscripts into UI
        ui_set_userscripts(app.ui, &app.userscripts);

        // Open URLs from command line, restore session, or open homepage
        if (app_url) {
            // App mode: single URL, insert mode (all keys pass through)
            create_tab(app_url);
            mode_set(&app.mode, MODE_INSERT);
        } else {
            int opened = 0;
            // CLI arguments: ./swim url1 url2 ...
            for (int i = 1; i < argc; i++) {
                if (argv[i][0] == '-') {
                    if (strcmp(argv[i], "--serve") == 0 && i + 1 < argc) {
                        char c = argv[i + 1][0];
                        if (c == '/' || c == '.' || (c >= '0' && c <= '9')) i++;
                    } else if (strcmp(argv[i], "--profile") == 0 && i + 1 < argc) {
                        i++;
                    } else if (strcmp(argv[i], "--app") == 0 && i + 1 < argc) {
                        i++;
                    }
                    continue;
                }
                create_tab(argv[i]);
                opened++;
            }
            if (!opened && app.config.restore_session) {
                char session_urls[128][2048];
                int session_count = session_load(app.session_path, session_urls, 128);
                if (session_count > 0) {
                    create_tab(session_urls[0]);
                    for (int i = 1; i < session_count; i++) {
                        int tab_id = browser_add_tab(&app.browser, session_urls[i]);
                        int idx = browser_find_tab(&app.browser, tab_id);
                        if (idx >= 0) app.browser.tabs[idx].lazy = true;
                        ui_add_tab(app.ui, NULL, tab_id, false);
                        ui_update_tab_title(app.ui, tab_id, session_urls[i]);
                    }
                    browser_set_active(&app.browser, 0);
                    ui_select_tab(app.ui, 0);
                    sync_tab_display();
                    opened = 1;
                }
            }
            if (!opened) {
                create_tab(app.config.homepage);
            }
        }

        if (serve) {
            static ServeContext serve_ctx;
            serve_ctx = (ServeContext){
                .ui = app.ui,
                .browser = &app.browser,
                .mode = &app.mode,
                .commands = &app.commands,
                .handle_action = handle_action,
                .action_ctx = &app,
            };
            serve_start(serve_addr, &serve_ctx);
        }

        // Key event monitor (skip in app mode — all keys pass through)
        if (!app_url)
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                // Don't intercept when command bar is focused
                if (app.mode.mode == MODE_COMMAND && !([event.characters isEqualToString:@"\x1b"])) {
                    return event;
                }

                // Don't intercept in INSERT mode (except Escape and Cmd shortcuts)
                if (app.mode.mode == MODE_INSERT && !([event.characters isEqualToString:@"\x1b"])
                    && !(event.modifierFlags & NSEventModifierFlagCommand)) {
                    return event;
                }

                const char *chars = [event.characters UTF8String];
                if (!chars || !chars[0]) return event;

                unsigned int mods = 0;
                NSEventModifierFlags flags = event.modifierFlags;
                if (flags & NSEventModifierFlagControl) mods |= MOD_CTRL;
                if (flags & NSEventModifierFlagShift)   mods |= MOD_SHIFT;
                if (flags & NSEventModifierFlagOption)   mods |= MOD_ALT;
                if (flags & NSEventModifierFlagCommand)  mods |= MOD_CMD;

                // Handle Cmd shortcuts we own, pass the rest through
                if (mods & MOD_CMD) {
                    const char *unmod = [event.charactersIgnoringModifiers UTF8String];
                    if (unmod) {
                        if (unmod[0] == '=' || unmod[0] == '+') {
                            ui_zoom_in(app.ui); return nil;
                        }
                        if (unmod[0] == '-') {
                            ui_zoom_out(app.ui); return nil;
                        }
                        if (unmod[0] == '0') {
                            ui_zoom_reset(app.ui); return nil;
                        }
                        if (unmod[0] == 'l') {
                            handle_action("command-open-current", &app); return nil;
                        }
                    }
                    return event;
                }

                bool consumed = mode_handle_key(&app.mode, chars, mods);
                // Show count prefix + pending keys in status bar
                char pending_display[64] = "";
                if (app.mode.count > 0)
                    snprintf(pending_display, sizeof(pending_display), "%d%s",
                        app.mode.count, app.mode.pending_keys);
                else
                    snprintf(pending_display, sizeof(pending_display), "%s",
                        app.mode.pending_keys);
                ui_set_pending_keys(app.ui, pending_display);
                return consumed ? nil : event;
            }];

        // Activate and run
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];

        // Save session (skip in app mode)
        if (!app_url) {
            const char *urls[128];
            int count = collect_tab_urls(urls, 128);
            session_save(app.session_path, urls, count);
        }

        // Cleanup
        if (!app_url) {
            storage_save(&app.history);
            storage_save(&app.bookmarks);
        }
        storage_free(&app.history);
        storage_free(&app.bookmarks);
        mode_free(&app.mode);
        registry_free(&app.commands);
        browser_free(&app.browser);
    }

    return 0;
}
