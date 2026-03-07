#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

void config_init(Config *c) {
    memset(c, 0, sizeof(*c));
    snprintf(c->homepage, sizeof(c->homepage), "https://duckduckgo.com");
    snprintf(c->search_engine, sizeof(c->search_engine), "https://duckduckgo.com/?q=%%s");
    c->restore_session = true;
    c->font_size = 12;
    c->show_tab_bar = true;
    c->show_status_bar = true;
    snprintf(c->theme, sizeof(c->theme), "dark");
    c->adblock_enabled = true;
}

static char *strip(char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    char *end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) *end-- = '\0';
    return s;
}

static void strip_quotes(char *s) {
    int len = strlen(s);
    if (len >= 2 && s[0] == '"' && s[len-1] == '"') {
        memmove(s, s + 1, len - 2);
        s[len - 2] = '\0';
    }
}

static void apply_kv(Config *c, const char *section, const char *key, const char *value) {
    char full_key[128];
    if (section[0]) {
        snprintf(full_key, sizeof(full_key), "%s.%s", section, key);
    } else {
        snprintf(full_key, sizeof(full_key), "%s", key);
    }

    config_set(c, full_key, value);
}

void config_load(Config *c, const char *filepath) {
    FILE *f = fopen(filepath, "r");
    if (!f) return;

    char section[64] = "";
    char line[4096];

    while (fgets(line, sizeof(line), f)) {
        char *p = strip(line);

        // Skip empty lines and comments
        if (!*p || *p == '#') continue;

        // Section header
        if (*p == '[') {
            char *end = strchr(p, ']');
            if (end) {
                *end = '\0';
                snprintf(section, sizeof(section), "%s", p + 1);
            }
            continue;
        }

        // Key = value
        char *eq = strchr(p, '=');
        if (!eq) continue;

        *eq = '\0';
        char *key = strip(p);
        char *val = strip(eq + 1);
        strip_quotes(val);

        apply_kv(c, section, key, val);
    }

    fclose(f);
}

bool config_set(Config *c, const char *key, const char *value) {
    if (strcmp(key, "general.homepage") == 0 || strcmp(key, "homepage") == 0) {
        snprintf(c->homepage, sizeof(c->homepage), "%s", value);
    } else if (strcmp(key, "general.search_engine") == 0 || strcmp(key, "search_engine") == 0) {
        snprintf(c->search_engine, sizeof(c->search_engine), "%s", value);
    } else if (strcmp(key, "general.restore_session") == 0 || strcmp(key, "restore_session") == 0) {
        c->restore_session = (strcmp(value, "true") == 0 || strcmp(value, "1") == 0);
    } else if (strcmp(key, "appearance.font_size") == 0 || strcmp(key, "font_size") == 0) {
        c->font_size = atoi(value);
        if (c->font_size < 8) c->font_size = 8;
        if (c->font_size > 32) c->font_size = 32;
    } else if (strcmp(key, "appearance.show_tab_bar") == 0 || strcmp(key, "show_tab_bar") == 0) {
        c->show_tab_bar = (strcmp(value, "true") == 0 || strcmp(value, "1") == 0);
    } else if (strcmp(key, "appearance.show_status_bar") == 0 || strcmp(key, "show_status_bar") == 0) {
        c->show_status_bar = (strcmp(value, "true") == 0 || strcmp(value, "1") == 0);
    } else if (strcmp(key, "appearance.theme") == 0 || strcmp(key, "theme") == 0) {
        snprintf(c->theme, sizeof(c->theme), "%s", value);
    } else if (strcmp(key, "adblock.enabled") == 0 || strcmp(key, "adblock") == 0) {
        c->adblock_enabled = (strcmp(value, "true") == 0 || strcmp(value, "1") == 0 || strcmp(value, "on") == 0);
    } else {
        return false;
    }
    return true;
}
