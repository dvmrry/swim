#ifndef SWIM_CONFIG_H
#define SWIM_CONFIG_H

#include <stdbool.h>

typedef struct KeyBinding {
    char keys[32];
    char action[64];
} KeyBinding;

typedef struct SearchShortcut {
    char prefix[16];
    char url_template[2048];
} SearchShortcut;

typedef struct Config {
    // [general]
    char homepage[2048];
    char search_engine[2048];
    bool restore_session;
    bool dark_mode;

    // [appearance]
    int font_size;
    char tab_bar[16];     // "always", "never", "auto"
    char status_bar[16];  // "always", "never", "auto"
    char theme[32];  // "dark" or "light"
    bool compact_titlebar;

    // [adblock]
    bool adblock_enabled;

    // [search]
    SearchShortcut search_shortcuts[16];
    int search_shortcut_count;

    // [proxy]
    char proxy_type[16];   // "none", "http", "socks5"
    char proxy_host[256];
    int proxy_port;

    // [keys.normal]
    KeyBinding key_bindings[64];
    int key_binding_count;
} Config;

// Load defaults, then override from file
void config_init(Config *c);
void config_load(Config *c, const char *filepath);

// Runtime `:set key value`
bool config_set(Config *c, const char *key, const char *value);

// Write current config to file
void config_save(Config *c, const char *filepath);

#endif
