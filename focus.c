#include "focus.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// Embedded default focus.js — written to disk on first run
static const char *kDefaultFocusJS =
#include "focus_js.inc"
;

static void theme_hex(ThemeColor c, char *buf) {
    snprintf(buf, 8, "#%02x%02x%02x",
        (int)(c.r * 255), (int)(c.g * 255), (int)(c.b * 255));
}

// Replace all occurrences of `from` with `to` in a malloc'd string
static char *str_replace_all(char *str, const char *from, const char *to) {
    int from_len = (int)strlen(from);
    int to_len = (int)strlen(to);
    char *p = str;
    while ((p = strstr(p, from))) {
        int tail = (int)strlen(p + from_len);
        int pos = (int)(p - str);
        if (to_len > from_len) {
            char *tmp = realloc(str, strlen(str) + (to_len - from_len) + 1);
            if (!tmp) return str;  // OOM: return what we have
            str = tmp;
            p = str + pos;
        }
        memmove(p + to_len, p + from_len, tail + 1);
        memcpy(p, to, to_len);
        p += to_len;
    }
    return str;
}

char *focus_build_js(SwimTheme *theme, const char *scripts_dir) {
    // Try loading from file first
    char path[512];
    snprintf(path, sizeof(path), "%s/focus.js", scripts_dir);

    char *tmpl = NULL;
    FILE *f = fopen(path, "r");
    if (f) {
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (len < 0) { fclose(f); return NULL; }
        tmpl = malloc(len + 1);
        if (tmpl) {
            fread(tmpl, 1, len, f);
            tmpl[len] = '\0';
        }
        fclose(f);
    }

    // Fall back to embedded default
    if (!tmpl) {
        tmpl = strdup(kDefaultFocusJS);
        if (!tmpl) return NULL;
    }

    // Build theme color values
    char bg[8], status_bg[8], fg[8], fg_dim[8], accent[8];
    theme_hex(theme->bg, bg);
    theme_hex(theme->status_bg, status_bg);
    theme_hex(theme->fg, fg);
    theme_hex(theme->fg_dim, fg_dim);
    theme_hex(theme->accent, accent);

    tmpl = str_replace_all(tmpl, "{{bg}}", bg);
    tmpl = str_replace_all(tmpl, "{{status_bg}}", status_bg);
    tmpl = str_replace_all(tmpl, "{{fg}}", fg);
    tmpl = str_replace_all(tmpl, "{{fg_dim}}", fg_dim);
    tmpl = str_replace_all(tmpl, "{{accent}}", accent);

    return tmpl;
}

void focus_create_default(const char *scripts_dir) {
    char path[512];
    snprintf(path, sizeof(path), "%s/focus.js", scripts_dir);

    struct stat st;
    if (stat(path, &st) == 0) return;  // already exists

    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%s", kDefaultFocusJS);
    fclose(f);
}
