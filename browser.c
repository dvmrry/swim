#include "browser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define INITIAL_CAP 8

void browser_init(Browser *b) {
    memset(b, 0, sizeof(*b));
    b->tab_capacity = INITIAL_CAP;
    b->tabs = calloc(INITIAL_CAP, sizeof(Tab));
    b->closed_capacity = INITIAL_CAP;
    b->closed_urls = calloc(INITIAL_CAP, sizeof(char *));
    b->active_tab = -1;
    b->next_id = 1;
}

int browser_add_tab(Browser *b, const char *url) {
    if (b->tab_count >= b->tab_capacity) {
        b->tab_capacity *= 2;
        b->tabs = realloc(b->tabs, b->tab_capacity * sizeof(Tab));
    }
    Tab *t = &b->tabs[b->tab_count];
    memset(t, 0, sizeof(Tab));
    t->id = b->next_id++;
    if (url) {
        snprintf(t->url, sizeof(t->url), "%s", url);
    }
    b->active_tab = b->tab_count;
    b->tab_count++;
    return t->id;
}

void browser_close_tab(Browser *b, int index) {
    if (index < 0 || index >= b->tab_count) return;

    // Push URL to closed stack
    Tab *t = &b->tabs[index];
    if (t->url[0]) {
        if (b->closed_count >= b->closed_capacity) {
            b->closed_capacity *= 2;
            b->closed_urls = realloc(b->closed_urls, b->closed_capacity * sizeof(char *));
        }
        b->closed_urls[b->closed_count++] = strdup(t->url);
    }

    // Shift remaining tabs
    for (int i = index; i < b->tab_count - 1; i++) {
        b->tabs[i] = b->tabs[i + 1];
    }
    b->tab_count--;

    if (b->tab_count == 0) {
        b->active_tab = -1;
    } else if (b->active_tab >= b->tab_count) {
        b->active_tab = b->tab_count - 1;
    }
}

Tab *browser_active(Browser *b) {
    if (b->active_tab < 0 || b->active_tab >= b->tab_count) return NULL;
    return &b->tabs[b->active_tab];
}

void browser_set_active(Browser *b, int index) {
    if (index >= 0 && index < b->tab_count) {
        b->active_tab = index;
    }
}

int browser_find_tab(Browser *b, int tab_id) {
    for (int i = 0; i < b->tab_count; i++) {
        if (b->tabs[i].id == tab_id) return i;
    }
    return -1;
}

void browser_tab_set_url(Browser *b, int tab_id, const char *url) {
    int i = browser_find_tab(b, tab_id);
    if (i >= 0) snprintf(b->tabs[i].url, sizeof(b->tabs[i].url), "%s", url);
}

void browser_tab_set_title(Browser *b, int tab_id, const char *title) {
    int i = browser_find_tab(b, tab_id);
    if (i >= 0) snprintf(b->tabs[i].title, sizeof(b->tabs[i].title), "%s", title);
}

void browser_tab_set_loading(Browser *b, int tab_id, bool loading, double progress) {
    int i = browser_find_tab(b, tab_id);
    if (i < 0) return;
    b->tabs[i].loading = loading;
    b->tabs[i].progress = progress;
}

void browser_free(Browser *b) {
    free(b->tabs);
    for (int i = 0; i < b->closed_count; i++) {
        free(b->closed_urls[i]);
    }
    free(b->closed_urls);
    memset(b, 0, sizeof(*b));
}
