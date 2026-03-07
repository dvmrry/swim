#ifndef SWIM_UI_H
#define SWIM_UI_H

#include "input.h"

// Opaque UI handle — implementation is ObjC
typedef struct SwimUI SwimUI;

// Callbacks from UI to app logic
typedef struct UICallbacks {
    void (*on_command_submit)(const char *text, void *ctx);
    void (*on_command_cancel)(void *ctx);
    void (*on_url_changed)(const char *url, int tab_id, void *ctx);
    void (*on_title_changed)(const char *title, int tab_id, void *ctx);
    void (*on_load_changed)(bool loading, double progress, int tab_id, void *ctx);
    void (*on_focus_changed)(bool focused, void *ctx);
    void (*on_tab_selected)(int index, void *ctx);
    void *ctx;
} UICallbacks;

// Create the UI (window, tab bar, webview area, status bar, command bar)
SwimUI *ui_create(UICallbacks callbacks);

// Tab management — returns tab_id for new tabs
int  ui_add_tab(SwimUI *ui, const char *url, int tab_id);
void ui_close_tab(SwimUI *ui, int index);
void ui_select_tab(SwimUI *ui, int index);
int  ui_tab_count(SwimUI *ui);
void ui_update_tab_title(SwimUI *ui, int tab_id, const char *title);

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

// Command bar
void ui_show_command_bar(SwimUI *ui, const char *prefill);
void ui_hide_command_bar(SwimUI *ui);

// Hint mode
void ui_show_hints(SwimUI *ui, bool new_tab);
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

// Window
void ui_set_window_title(SwimUI *ui, const char *title);
void ui_close(SwimUI *ui);

#endif
