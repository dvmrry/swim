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
    void *ctx;
} UICallbacks;

// Create the UI (window, webview, status bar, command bar)
SwimUI *ui_create(UICallbacks callbacks);

// WebView control
void ui_navigate(SwimUI *ui, const char *url);
void ui_run_js(SwimUI *ui, const char *js);

// Status bar updates
void ui_set_mode(SwimUI *ui, Mode mode);
void ui_set_url(SwimUI *ui, const char *url);
void ui_set_progress(SwimUI *ui, double progress);

// Command bar
void ui_show_command_bar(SwimUI *ui, const char *prefill);
void ui_hide_command_bar(SwimUI *ui);

// Window
void ui_close(SwimUI *ui);

#endif
