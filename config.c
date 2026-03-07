#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <sys/stat.h>

static void add_search_shortcut(Config *c, const char *prefix, const char *url_template) {
    if (c->search_shortcut_count >= 16) return;
    SearchShortcut *s = &c->search_shortcuts[c->search_shortcut_count++];
    snprintf(s->prefix, sizeof(s->prefix), "%s", prefix);
    snprintf(s->url_template, sizeof(s->url_template), "%s", url_template);
}

void config_init(Config *c) {
    memset(c, 0, sizeof(*c));
    snprintf(c->homepage, sizeof(c->homepage), "https://duckduckgo.com");
    snprintf(c->search_engine, sizeof(c->search_engine), "https://duckduckgo.com/?q=%%s");
    c->restore_session = true;
    c->dark_mode = true;
    c->font_size = 12;
    snprintf(c->tab_bar, sizeof(c->tab_bar), "auto");
    snprintf(c->status_bar, sizeof(c->status_bar), "always");
    snprintf(c->theme, sizeof(c->theme), "dark");
    c->compact_titlebar = false;
    c->adblock_enabled = true;
    snprintf(c->proxy_type, sizeof(c->proxy_type), "none");

    // Default search shortcuts
    add_search_shortcut(c, "g", "https://www.google.com/search?q=%s");
    add_search_shortcut(c, "ddg", "https://duckduckgo.com/?q=%s");
    add_search_shortcut(c, "w", "https://en.wikipedia.org/w/index.php?search=%s");
    add_search_shortcut(c, "gh", "https://github.com/search?q=%s");
    add_search_shortcut(c, "yt", "https://www.youtube.com/results?search_query=%s");
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

static void write_if_missing(const char *path, const char *content) {
    struct stat st;
    if (stat(path, &st) == 0) return;
    FILE *f = fopen(path, "w");
    if (!f) return;
    fputs(content, f);
    fclose(f);
}

void config_create_default_profiles(const char *dir_path) {
    char path[512];

    snprintf(path, sizeof(path), "%s/casual.toml", dir_path);
    write_if_missing(path,
        "# swim profile: casual\n"
        "# Visible UI elements, larger text\n"
        "[appearance]\n"
        "tab_bar = \"always\"\n"
        "status_bar = \"always\"\n"
        "font_size = 16\n");

    snprintf(path, sizeof(path), "%s/minimal.toml", dir_path);
    write_if_missing(path,
        "# swim profile: minimal\n"
        "# Hide everything, maximum content space\n"
        "[appearance]\n"
        "tab_bar = \"never\"\n"
        "status_bar = \"never\"\n"
        "compact_titlebar = true\n");
}

static bool parse_bool(const char *value) {
    return strcmp(value, "true") == 0 || strcmp(value, "1") == 0;
}

static bool parse_bar_mode(const char *value, char *dest, int dest_size) {
    if (strcmp(value, "always") == 0 || strcmp(value, "true") == 0 || strcmp(value, "1") == 0) {
        snprintf(dest, dest_size, "always");
    } else if (strcmp(value, "never") == 0 || strcmp(value, "false") == 0 || strcmp(value, "0") == 0) {
        snprintf(dest, dest_size, "never");
    } else if (strcmp(value, "auto") == 0) {
        snprintf(dest, dest_size, "auto");
    } else {
        return false;
    }
    return true;
}

bool config_set(Config *c, const char *key, const char *value) {
    if (strcmp(key, "general.homepage") == 0 || strcmp(key, "homepage") == 0) {
        snprintf(c->homepage, sizeof(c->homepage), "%s", value);
    } else if (strcmp(key, "general.search_engine") == 0 || strcmp(key, "search_engine") == 0) {
        snprintf(c->search_engine, sizeof(c->search_engine), "%s", value);
    } else if (strcmp(key, "general.restore_session") == 0 || strcmp(key, "restore_session") == 0) {
        c->restore_session = parse_bool(value);
    } else if (strcmp(key, "appearance.font_size") == 0 || strcmp(key, "font_size") == 0) {
        int v = atoi(value);
        if (v < 8 || v > 32) return false;
        c->font_size = v;
    } else if (strcmp(key, "appearance.tab_bar") == 0 || strcmp(key, "tab_bar") == 0) {
        if (!parse_bar_mode(value, c->tab_bar, sizeof(c->tab_bar))) return false;
    } else if (strcmp(key, "appearance.status_bar") == 0 || strcmp(key, "status_bar") == 0) {
        if (!parse_bar_mode(value, c->status_bar, sizeof(c->status_bar))) return false;
    } else if (strcmp(key, "appearance.theme") == 0 || strcmp(key, "theme") == 0) {
        snprintf(c->theme, sizeof(c->theme), "%s", value);
    } else if (strcmp(key, "appearance.compact_titlebar") == 0 || strcmp(key, "compact_titlebar") == 0) {
        c->compact_titlebar = parse_bool(value);
    } else if (strcmp(key, "adblock.enabled") == 0 || strcmp(key, "adblock") == 0) {
        c->adblock_enabled = parse_bool(value) || strcmp(value, "on") == 0;
    } else if (strcmp(key, "general.dark_mode") == 0 || strcmp(key, "dark_mode") == 0) {
        c->dark_mode = parse_bool(value);
    } else if (strncmp(key, "search.", 7) == 0) {
        // search.g = https://google.com/search?q=%s
        const char *prefix = key + 7;
        if (prefix[0]) {
            // Check if shortcut already exists, update it
            bool found = false;
            for (int i = 0; i < c->search_shortcut_count; i++) {
                if (strcmp(c->search_shortcuts[i].prefix, prefix) == 0) {
                    snprintf(c->search_shortcuts[i].url_template,
                        sizeof(c->search_shortcuts[i].url_template), "%s", value);
                    found = true;
                    break;
                }
            }
            if (!found) add_search_shortcut(c, prefix, value);
        }
    } else if (strcmp(key, "proxy.type") == 0 || strcmp(key, "proxy_type") == 0) {
        snprintf(c->proxy_type, sizeof(c->proxy_type), "%s", value);
    } else if (strcmp(key, "proxy.host") == 0 || strcmp(key, "proxy_host") == 0) {
        snprintf(c->proxy_host, sizeof(c->proxy_host), "%s", value);
    } else if (strcmp(key, "proxy.port") == 0 || strcmp(key, "proxy_port") == 0) {
        c->proxy_port = atoi(value);
    } else if (strncmp(key, "keys.normal.", 12) == 0) {
        if (c->key_binding_count < 64) {
            KeyBinding *kb = &c->key_bindings[c->key_binding_count++];
            snprintf(kb->keys, sizeof(kb->keys), "%s", key + 12);
            snprintf(kb->action, sizeof(kb->action), "%s", value);
        }
    } else {
        return false;
    }
    return true;
}

void config_save(Config *c, const char *filepath) {
    FILE *f = fopen(filepath, "w");
    if (!f) return;

    fprintf(f, "[general]\n");
    fprintf(f, "homepage = \"%s\"\n", c->homepage);
    fprintf(f, "search_engine = \"%s\"\n", c->search_engine);
    fprintf(f, "restore_session = %s\n", c->restore_session ? "true" : "false");
    fprintf(f, "dark_mode = %s\n", c->dark_mode ? "true" : "false");

    fprintf(f, "\n[appearance]\n");
    fprintf(f, "font_size = %d\n", c->font_size);
    fprintf(f, "tab_bar = \"%s\"\n", c->tab_bar);
    fprintf(f, "status_bar = \"%s\"\n", c->status_bar);
    fprintf(f, "theme = \"%s\"\n", c->theme);
    fprintf(f, "compact_titlebar = %s\n", c->compact_titlebar ? "true" : "false");

    fprintf(f, "\n[adblock]\n");
    fprintf(f, "enabled = %s\n", c->adblock_enabled ? "true" : "false");

    if (c->search_shortcut_count > 0) {
        fprintf(f, "\n[search]\n");
        for (int i = 0; i < c->search_shortcut_count; i++) {
            fprintf(f, "%s = \"%s\"\n",
                c->search_shortcuts[i].prefix, c->search_shortcuts[i].url_template);
        }
    }

    if (strcmp(c->proxy_type, "none") != 0 && c->proxy_host[0]) {
        fprintf(f, "\n[proxy]\n");
        fprintf(f, "type = \"%s\"\n", c->proxy_type);
        fprintf(f, "host = \"%s\"\n", c->proxy_host);
        fprintf(f, "port = %d\n", c->proxy_port);
    }

    if (c->key_binding_count > 0) {
        fprintf(f, "\n[keys.normal]\n");
        for (int i = 0; i < c->key_binding_count; i++) {
            fprintf(f, "%s = \"%s\"\n", c->key_bindings[i].keys, c->key_bindings[i].action);
        }
    }

    fclose(f);
}
