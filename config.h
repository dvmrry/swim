#ifndef SWIM_CONFIG_H
#define SWIM_CONFIG_H

#include <stdbool.h>

typedef struct Config {
    // [general]
    char homepage[2048];
    char search_engine[2048];
    bool restore_session;

    // [appearance]
    int font_size;
    bool show_tab_bar;
    bool show_status_bar;
    char theme[32];  // "dark" or "light"

    // [adblock]
    bool adblock_enabled;
} Config;

// Load defaults, then override from file
void config_init(Config *c);
void config_load(Config *c, const char *filepath);

// Runtime `:set key value`
bool config_set(Config *c, const char *key, const char *value);

#endif
