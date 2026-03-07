#ifndef SWIM_BROWSER_H
#define SWIM_BROWSER_H

#include <stdbool.h>

typedef struct Tab {
    int id;
    char url[2048];
    char title[256];
    char last_error[512];  // last navigation error, empty if none
    bool loading;
    bool lazy;      // deferred load: navigate on first select
    double progress;
    void *webview;  // opaque, WKWebView* on macOS
} Tab;

typedef struct Browser {
    Tab *tabs;
    int tab_count;
    int tab_capacity;
    int active_tab;
    int next_id;

    // Closed tab stack for undo
    char **closed_urls;
    int closed_count;
    int closed_capacity;
} Browser;

void browser_init(Browser *b);
int  browser_add_tab(Browser *b, const char *url);
void browser_close_tab(Browser *b, int index);
Tab *browser_active(Browser *b);
void browser_set_active(Browser *b, int index);
void browser_free(Browser *b);

// Update tab state (called from navigation delegates)
void browser_tab_set_url(Browser *b, int tab_id, const char *url);
void browser_tab_set_title(Browser *b, int tab_id, const char *title);
void browser_tab_set_loading(Browser *b, int tab_id, bool loading, double progress);
void browser_tab_set_error(Browser *b, int tab_id, const char *error);
void browser_tab_clear_error(Browser *b, int tab_id);

// Find tab by id, returns index or -1
int browser_find_tab(Browser *b, int tab_id);

// Move tab from one index to another
void browser_move_tab(Browser *b, int from, int to);

#endif
