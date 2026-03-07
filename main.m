#import <Cocoa/Cocoa.h>
#include "browser.h"
#include "input.h"
#include "commands.h"
#include "ui.h"

// --- App State ---

typedef struct App {
    Browser browser;
    ModeManager mode;
    CommandRegistry commands;
    SwimUI *ui;
} App;

static App app;

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
    } else if (strcmp(action, "scroll-top") == 0) {
        ui_run_js(app.ui, "window.scrollTo(0, 0)");
    } else if (strcmp(action, "scroll-bottom") == 0) {
        ui_run_js(app.ui, "window.scrollTo(0, document.body.scrollHeight)");
    } else if (strcmp(action, "close-tab") == 0) {
        // For now with single tab, just quit
        ui_close(app.ui);
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
        ui_run_js(app.ui, "location.reload()");
    } else if (strcmp(action, "back") == 0) {
        ui_run_js(app.ui, "history.back()");
    } else if (strcmp(action, "forward") == 0) {
        ui_run_js(app.ui, "history.forward()");
    } else if (strcmp(action, "mode-normal") == 0) {
        ui_set_mode(app.ui, MODE_NORMAL);
        ui_hide_command_bar(app.ui);
        ui_run_js(app.ui, "document.activeElement.blur()");
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

    // If no dots or slashes, treat as search
    if (!strchr(args, '.') && !strchr(args, '/') && strncmp(args, "http", 4) != 0) {
        char search_url[4096];
        snprintf(search_url, sizeof(search_url), "https://duckduckgo.com/?q=%s", args);
        ui_navigate(app.ui, search_url);
    } else {
        ui_navigate(app.ui, args);
    }

    Tab *t = browser_active(&app.browser);
    if (t) snprintf(t->url, sizeof(t->url), "%s", args);
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
}

static void on_title_changed(const char *title, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_title(&app.browser, tab_id, title);
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

// --- Main ---

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Init pure C state
        browser_init(&app.browser);
        mode_init(&app.mode, handle_action, &app);
        registry_init(&app.commands, &app);
        registry_add(&app.commands, "open", "o", cmd_open, "Navigate to URL");
        registry_add(&app.commands, "tabopen", "to", cmd_open, "Open in new tab");  // same as open for now
        registry_add(&app.commands, "quit", "q", cmd_quit, "Quit swim");

        // Create UI
        UICallbacks callbacks = {
            .on_command_submit = on_command_submit,
            .on_command_cancel = on_command_cancel,
            .on_url_changed = on_url_changed,
            .on_title_changed = on_title_changed,
            .on_load_changed = on_load_changed,
            .on_focus_changed = on_focus_changed,
            .ctx = &app,
        };
        app.ui = ui_create(callbacks);

        // Create first tab
        browser_add_tab(&app.browser, "https://duckduckgo.com");
        ui_navigate(app.ui, "https://duckduckgo.com");

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

        // Cleanup
        mode_free(&app.mode);
        registry_free(&app.commands);
        browser_free(&app.browser);
    }

    return 0;
}
