#include "theme.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <sys/stat.h>

static ThemeColor hex_to_color(const char *hex) {
    ThemeColor c = {0, 0, 0};
    if (hex[0] == '#') hex++;
    if (strlen(hex) < 6) return c;
    unsigned int r, g, b;
    if (sscanf(hex, "%2x%2x%2x", &r, &g, &b) == 3) {
        c.r = r / 255.0f;
        c.g = g / 255.0f;
        c.b = b / 255.0f;
    }
    return c;
}

void theme_init_defaults(SwimTheme *t) {
    memset(t, 0, sizeof(*t));
    snprintf(t->name, sizeof(t->name), "default");
    t->bg          = (ThemeColor){0.12f, 0.12f, 0.14f};
    t->status_bg   = (ThemeColor){0.13f, 0.13f, 0.15f};
    t->fg          = (ThemeColor){0.90f, 0.90f, 0.90f};
    t->fg_dim      = (ThemeColor){0.45f, 0.45f, 0.45f};
    t->normal      = (ThemeColor){0.45f, 0.70f, 0.45f};
    t->insert      = (ThemeColor){0.45f, 0.55f, 0.85f};
    t->command     = (ThemeColor){0.82f, 0.75f, 0.40f};
    t->hint        = (ThemeColor){0.90f, 0.55f, 0.25f};
    t->passthrough = (ThemeColor){0.65f, 0.45f, 0.78f};
    t->accent      = (ThemeColor){0.50f, 0.70f, 0.90f};
}

static void apply_kv(SwimTheme *t, const char *key, const char *value) {
    ThemeColor c = hex_to_color(value);
    if (strcmp(key, "bg") == 0)               t->bg = c;
    else if (strcmp(key, "status-bg") == 0)    t->status_bg = c;
    else if (strcmp(key, "fg") == 0)           t->fg = c;
    else if (strcmp(key, "fg-dim") == 0)       t->fg_dim = c;
    else if (strcmp(key, "normal") == 0)       t->normal = c;
    else if (strcmp(key, "insert") == 0)       t->insert = c;
    else if (strcmp(key, "command") == 0)      t->command = c;
    else if (strcmp(key, "hint") == 0)         t->hint = c;
    else if (strcmp(key, "passthrough") == 0)  t->passthrough = c;
    else if (strcmp(key, "accent") == 0)       t->accent = c;
}

bool theme_load(SwimTheme *t, const char *filepath) {
    FILE *f = fopen(filepath, "r");
    if (!f) return false;

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p && isspace((unsigned char)*p)) p++;
        if (!*p || *p == '#') continue;

        char *eq = strchr(p, '=');
        if (!eq) continue;

        *eq = '\0';
        char *key = p;
        char *val = eq + 1;

        char *kend = eq - 1;
        while (kend > key && isspace((unsigned char)*kend)) *kend-- = '\0';

        while (*val && isspace((unsigned char)*val)) val++;
        char *vend = val + strlen(val) - 1;
        while (vend > val && isspace((unsigned char)*vend)) *vend-- = '\0';

        if (strcmp(key, "name") == 0) {
            snprintf(t->name, sizeof(t->name), "%s", val);
        } else {
            apply_kv(t, key, val);
        }
    }

    fclose(f);
    return true;
}

static const char *kTokyoNight =
    "# Tokyo Night\n"
    "bg = #1a1b26\n"
    "status-bg = #16161e\n"
    "fg = #c0caf5\n"
    "fg-dim = #565f89\n"
    "normal = #9ece6a\n"
    "insert = #7aa2f7\n"
    "command = #e0af68\n"
    "hint = #ff9e64\n"
    "passthrough = #bb9af7\n"
    "accent = #7aa2f7\n";

static const char *kKanagawa =
    "# Kanagawa Wave\n"
    "bg = #1f1f28\n"
    "status-bg = #16161d\n"
    "fg = #dcd7ba\n"
    "fg-dim = #727169\n"
    "normal = #76946a\n"
    "insert = #7e9cd8\n"
    "command = #e6c384\n"
    "hint = #ffa066\n"
    "passthrough = #957fb8\n"
    "accent = #7fb4ca\n";

void theme_create_defaults(const char *dir_path) {
    struct stat st;
    if (stat(dir_path, &st) == 0) return;

    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", dir_path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0700);
            *p = '/';
        }
    }
    mkdir(tmp, 0700);

    char path[1024];

    snprintf(path, sizeof(path), "%s/tokyonight.theme", dir_path);
    FILE *f = fopen(path, "w");
    if (f) { fputs(kTokyoNight, f); fclose(f); }

    snprintf(path, sizeof(path), "%s/kanagawa.theme", dir_path);
    f = fopen(path, "w");
    if (f) { fputs(kKanagawa, f); fclose(f); }
}
