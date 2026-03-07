#import <Cocoa/Cocoa.h>
#include "browser.h"
#include "input.h"
#include "commands.h"
#include "ui.h"
#include "storage.h"

// --- App State ---

typedef struct App {
    Browser browser;
    ModeManager mode;
    CommandRegistry commands;
    SwimUI *ui;
    Storage bookmarks;
    Storage history;
    char session_path[512];
} App;

static App app;

// --- Helpers ---

static void open_url_in_active_tab(const char *raw) {
    if (!raw || !raw[0]) return;

    // If no dots or slashes, treat as search
    if (!strchr(raw, '.') && !strchr(raw, '/') && strncmp(raw, "http", 4) != 0) {
        char search_url[4096];
        snprintf(search_url, sizeof(search_url), "https://duckduckgo.com/?q=%s", raw);
        ui_navigate(app.ui, search_url);
    } else {
        ui_navigate(app.ui, raw);
    }
}

static void create_tab(const char *url) {
    int tab_id = browser_add_tab(&app.browser, url ? url : "");
    ui_add_tab(app.ui, url, tab_id);

    Tab *t = browser_active(&app.browser);
    if (t && t->url[0]) {
        ui_set_url(app.ui, t->url);
    } else {
        ui_set_url(app.ui, "");
    }
}

static void sync_tab_display(void) {
    Tab *t = browser_active(&app.browser);
    if (t) {
        ui_set_url(app.ui, t->url);
    } else {
        ui_set_url(app.ui, "");
    }
}

// --- Actions (from key bindings) ---

static void handle_action(const char *action, void *ctx) {
    (void)ctx;

    if (strcmp(action, "scroll-down") == 0) {
        ui_run_js(app.ui, "window.scrollBy(0, 60)");
    } else if (strcmp(action, "scroll-up") == 0) {
        ui_run_js(app.ui, "window.scrollBy(0, -60)");
    } else if (strcmp(action, "scroll-left") == 0) {
        ui_run_js(app.ui, "window.scrollBy(-60, 0)");
    } else if (strcmp(action, "scroll-right") == 0) {
        ui_run_js(app.ui, "window.scrollBy(60, 0)");
    } else if (strcmp(action, "scroll-half-down") == 0) {
        ui_run_js(app.ui, "window.scrollBy(0, window.innerHeight / 2)");
    } else if (strcmp(action, "scroll-half-up") == 0) {
        ui_run_js(app.ui, "window.scrollBy(0, -window.innerHeight / 2)");
    } else if (strcmp(action, "scroll-full-down") == 0) {
        ui_run_js(app.ui, "window.scrollBy(0, window.innerHeight)");
    } else if (strcmp(action, "scroll-full-up") == 0) {
        ui_run_js(app.ui, "window.scrollBy(0, -window.innerHeight)");
    } else if (strcmp(action, "scroll-top") == 0) {
        ui_run_js(app.ui, "window.scrollTo(0, 0)");
    } else if (strcmp(action, "scroll-bottom") == 0) {
        ui_run_js(app.ui, "window.scrollTo(0, document.body.scrollHeight)");
    } else if (strcmp(action, "close-tab") == 0) {
        int idx = app.browser.active_tab;
        if (app.browser.tab_count <= 1) {
            ui_close(app.ui);
            return;
        }
        browser_close_tab(&app.browser, idx);
        ui_close_tab(app.ui, idx);
        // Sync browser active tab with UI
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
        browser_set_active(&app.browser, idx);
        ui_select_tab(app.ui, idx);
        sync_tab_display();
    } else if (strcmp(action, "next-tab") == 0) {
        int idx = app.browser.active_tab + 1;
        if (idx >= app.browser.tab_count) idx = 0;
        browser_set_active(&app.browser, idx);
        ui_select_tab(app.ui, idx);
        sync_tab_display();
    } else if (strcmp(action, "enter-command") == 0) {
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
        ui_show_command_bar(app.ui, "");
    } else if (strcmp(action, "command-open") == 0) {
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
        ui_show_command_bar(app.ui, "open ");
    } else if (strcmp(action, "command-open-current") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t) {
            char prefill[2100];
            snprintf(prefill, sizeof(prefill), "open %s", t->url);
            mode_set(&app.mode, MODE_COMMAND);
            ui_set_mode(app.ui, MODE_COMMAND);
            ui_show_command_bar(app.ui, prefill);
        }
    } else if (strcmp(action, "command-tabopen") == 0) {
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
        ui_show_command_bar(app.ui, "tabopen ");
    } else if (strcmp(action, "reload") == 0) {
        ui_reload(app.ui);
    } else if (strcmp(action, "back") == 0) {
        ui_go_back(app.ui);
    } else if (strcmp(action, "forward") == 0) {
        ui_go_forward(app.ui);
    } else if (strcmp(action, "mode-normal") == 0) {
        ui_set_mode(app.ui, MODE_NORMAL);
        ui_hide_command_bar(app.ui);
        ui_run_js(app.ui, "document.activeElement.blur()");
    } else if (strcmp(action, "hint-follow") == 0) {
        mode_set(&app.mode, MODE_HINT);
        ui_set_mode(app.ui, MODE_HINT);
        ui_show_hints(app.ui, false);
    } else if (strcmp(action, "hint-tab") == 0) {
        mode_set(&app.mode, MODE_HINT);
        ui_set_mode(app.ui, MODE_HINT);
        ui_show_hints(app.ui, true);
    } else if (strcmp(action, "hint-filter") == 0) {
        ui_filter_hints(app.ui, app.mode.pending_keys);
    } else if (strcmp(action, "hint-cancel") == 0) {
        ui_cancel_hints(app.ui);
    } else if (strcmp(action, "find") == 0) {
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
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
    create_tab(NULL);
    if (args && args[0]) {
        open_url_in_active_tab(args);
        Tab *t = browser_active(&app.browser);
        if (t) snprintf(t->url, sizeof(t->url), "%s", args);
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

static void cmd_adblock(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0] || strcmp(args, "on") == 0) {
        ui_set_adblock(app.ui, true);
    } else if (strcmp(args, "off") == 0) {
        ui_set_adblock(app.ui, false);
    }
}

static void cmd_quit(const char *args, void *ctx) {
    (void)args; (void)ctx;
    ui_close(app.ui);
}

// --- UI Callbacks ---

static void on_command_submit(const char *text, void *ctx) {
    (void)ctx;
    mode_set(&app.mode, MODE_NORMAL);
    ui_set_mode(app.ui, MODE_NORMAL);
    ui_hide_command_bar(app.ui);
    registry_exec(&app.commands, text);
}

static void on_command_cancel(void *ctx) {
    (void)ctx;
    mode_set(&app.mode, MODE_NORMAL);
    ui_set_mode(app.ui, MODE_NORMAL);
    ui_hide_command_bar(app.ui);
}

static void on_url_changed(const char *url, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_url(&app.browser, tab_id, url);
    Tab *t = browser_active(&app.browser);
    if (t && t->id == tab_id) {
        ui_set_url(app.ui, url);
    }
    // Record in history
    if (url && strncmp(url, "about:", 6) != 0) {
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

static void on_focus_changed(bool focused, void *ctx) {
    (void)ctx;
    if (focused) {
        mode_set(&app.mode, MODE_INSERT);
        ui_set_mode(app.ui, MODE_INSERT);
    } else {
        mode_set(&app.mode, MODE_NORMAL);
        ui_set_mode(app.ui, MODE_NORMAL);
    }
}

static void on_tab_selected(int index, void *ctx) {
    (void)ctx;
    browser_set_active(&app.browser, index);
    ui_select_tab(app.ui, index);
    sync_tab_display();
}

// --- Main ---

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Ensure config dir exists
        storage_ensure_dir();

        // Init storage
        const char *home = getenv("HOME");
        char bm_path[512], hist_path[512];
        snprintf(bm_path, sizeof(bm_path), "%s/.config/swim/bookmarks.json", home ? home : ".");
        snprintf(hist_path, sizeof(hist_path), "%s/.config/swim/history.json", home ? home : ".");
        storage_init(&app.bookmarks, bm_path);
        storage_init(&app.history, hist_path);
        storage_load(&app.bookmarks);
        storage_load(&app.history);
        snprintf(app.session_path, sizeof(app.session_path),
            "%s/.config/swim/session.json", home ? home : ".");

        // Init pure C state
        browser_init(&app.browser);
        mode_init(&app.mode, handle_action, &app);
        registry_init(&app.commands, &app);
        registry_add(&app.commands, "open", "o", cmd_open, "Navigate to URL");
        registry_add(&app.commands, "tabopen", "to", cmd_tabopen, "Open in new tab");
        registry_add(&app.commands, "quit", "q", cmd_quit, "Quit swim");
        registry_add(&app.commands, "adblock", NULL, cmd_adblock, "Toggle adblock on/off");
        registry_add(&app.commands, "bookmark", "bm", cmd_bookmark, "Bookmark current page");
        registry_add(&app.commands, "marks", NULL, cmd_marks, "Search bookmarks");
        registry_add(&app.commands, "history", NULL, cmd_history, "Search history");

        // Create UI
        UICallbacks callbacks = {
            .on_command_submit = on_command_submit,
            .on_command_cancel = on_command_cancel,
            .on_url_changed = on_url_changed,
            .on_title_changed = on_title_changed,
            .on_load_changed = on_load_changed,
            .on_focus_changed = on_focus_changed,
            .on_tab_selected = on_tab_selected,
            .ctx = &app,
        };
        app.ui = ui_create(callbacks);

        // Load adblock rules
        ui_load_blocklist(app.ui);

        // Restore session or create default tab
        {
            char session_urls[128][2048];
            int session_count = session_load(app.session_path, session_urls, 128);
            if (session_count > 0) {
                for (int i = 0; i < session_count; i++) {
                    create_tab(session_urls[i]);
                }
                // Select first tab
                browser_set_active(&app.browser, 0);
                ui_select_tab(app.ui, 0);
                sync_tab_display();
            } else {
                create_tab("https://duckduckgo.com");
            }
        }

        // Key event monitor
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                // Don't intercept when command bar is focused
                if (app.mode.mode == MODE_COMMAND && !([event.characters isEqualToString:@"\x1b"])) {
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

                // Let Cmd shortcuts pass through (Cmd-Q, Cmd-C, etc.)
                if (mods & MOD_CMD) return event;

                bool consumed = mode_handle_key(&app.mode, chars, mods);
                return consumed ? nil : event;
            }];

        // Activate and run
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];

        // Save session
        {
            const char *urls[128];
            int count = 0;
            for (int i = 0; i < app.browser.tab_count && count < 128; i++) {
                if (app.browser.tabs[i].url[0]) {
                    urls[count++] = app.browser.tabs[i].url;
                }
            }
            session_save(app.session_path, urls, count);
        }

        // Cleanup
        storage_save(&app.history);
        storage_save(&app.bookmarks);
        storage_free(&app.history);
        storage_free(&app.bookmarks);
        mode_free(&app.mode);
        registry_free(&app.commands);
        browser_free(&app.browser);
    }

    return 0;
}
