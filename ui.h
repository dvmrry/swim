#ifndef SWIM_UI_H
#define SWIM_UI_H

#include "input.h"
#include "userscript.h"
#include "theme.h"

// Opaque UI handle — implementation is ObjC
typedef struct SwimUI SwimUI;

// Callbacks from UI to app logic
typedef struct UICallbacks {
    void (*on_command_submit)(const char *text, void *ctx);
    void (*on_command_cancel)(void *ctx);
    void (*on_url_changed)(const char *url, int tab_id, void *ctx);
    void (*on_title_changed)(const char *title, int tab_id, void *ctx);
    void (*on_load_changed)(bool loading, double progress, int tab_id, void *ctx);
    void (*on_nav_error)(const char *error, int tab_id, void *ctx);
    void (*on_focus_changed)(bool focused, void *ctx);
    void (*on_hints_done)(void *ctx);
    void (*on_tab_selected)(int index, void *ctx);
    const char *(*on_command_complete)(const char *prefix, const char *cmd_prefix, void *ctx);
    void *ctx;
} UICallbacks;

// Create the UI (window, tab bar, webview area, status bar, command bar)
SwimUI *ui_create(UICallbacks callbacks, bool compact_titlebar, const char *tab_bar_mode, const char *status_bar_mode, SwimTheme *theme);

// Tab management — returns tab_id for new tabs
int  ui_add_tab(SwimUI *ui, const char *url, int tab_id, bool private_tab);
void ui_close_tab(SwimUI *ui, int index);
void ui_select_tab(SwimUI *ui, int index);
int  ui_tab_count(SwimUI *ui);
void ui_update_tab_title(SwimUI *ui, int tab_id, const char *title);
void ui_move_tab(SwimUI *ui, int from, int to);
bool ui_tab_is_private(SwimUI *ui, int tab_id);

// WebView control (operates on active tab)
void ui_navigate(SwimUI *ui, const char *url);
void ui_run_js(SwimUI *ui, const char *js);
void ui_reload(SwimUI *ui);
void ui_go_back(SwimUI *ui);
void ui_go_forward(SwimUI *ui);

// Status bar updates
void ui_set_mode(SwimUI *ui, Mode mode);
void ui_set_url(SwimUI *ui, const char *url);
void ui_set_progress(SwimUI *ui, double progress);
void ui_set_pending_keys(SwimUI *ui, const char *keys);
void ui_set_status_message(SwimUI *ui, const char *msg);

// Command bar
// prefix: command name prepended on submit and shown in label (e.g. "open ")
// value: initial text in field (e.g. current URL for O)
// placeholder: shown when field is empty (e.g. current URL for o)
void ui_show_command_bar(SwimUI *ui, const char *prefix, const char *value, const char *placeholder);
void ui_hide_command_bar(SwimUI *ui);

// Hint mode: 0=click, 1=new tab, 2=yank URL
void ui_show_hints(SwimUI *ui, int mode);
void ui_filter_hints(SwimUI *ui, const char *typed);
void ui_cancel_hints(SwimUI *ui);

// Find in page
void ui_show_find_bar(SwimUI *ui);
void ui_hide_find_bar(SwimUI *ui);
void ui_find_next(SwimUI *ui);
void ui_find_prev(SwimUI *ui);

// Content blocking
void ui_load_blocklist(SwimUI *ui);
void ui_set_adblock(SwimUI *ui, bool enabled);

// Zoom
void ui_zoom_in(SwimUI *ui);
void ui_zoom_out(SwimUI *ui);
void ui_zoom_reset(SwimUI *ui);

// Window
void ui_set_window_title(SwimUI *ui, const char *title);
void ui_close(SwimUI *ui);

// Runtime config updates
void ui_set_tab_bar_mode(SwimUI *ui, const char *mode);
void ui_set_status_bar_mode(SwimUI *ui, const char *mode);

// Userscripts — call before creating any tabs
void ui_set_userscripts(SwimUI *ui, UserScriptManager *scripts);

// Dark mode — sets webview prefers-color-scheme
void ui_set_dark_mode(SwimUI *ui, bool enabled);

// Tab audio mute toggle (current tab)
void ui_toggle_mute(SwimUI *ui);

// Open web inspector for current tab
void ui_open_inspector(SwimUI *ui);

// Proxy — apply to data store for future navigations
void ui_set_proxy(SwimUI *ui, const char *type, const char *host, int port);

// Capture active tab as PNG. Returns NSData* (cast to void*).
void *ui_screenshot(SwimUI *ui);
void *ui_get_window(SwimUI *ui);
bool ui_is_loading(SwimUI *ui);
void *ui_get_active_webview(SwimUI *ui);

// Dialog queue for serving mode
void ui_set_serving(SwimUI *ui, bool serving);
void *ui_get_dialog_queue(SwimUI *ui);  // returns NSMutableArray*

#endif
