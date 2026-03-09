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

// Simple template substitution: replace all {{key}} with value
static char *substitute(const char *tmpl, const char *keys[], const char *vals[], int count) {
    // First pass: compute output size
    size_t len = strlen(tmpl);
    size_t out_len = len;
    const char *p = tmpl;
    while ((p = strstr(p, "{{"))) {
        const char *end = strstr(p + 2, "}}");
        if (!end) break;
        int klen = (int)(end - p - 2);
        for (int i = 0; i < count; i++) {
            if ((int)strlen(keys[i]) == klen && strncmp(p + 2, keys[i], klen) == 0) {
                out_len = out_len - (klen + 4) + strlen(vals[i]);
                break;
            }
        }
        p = end + 2;
    }

    char *out = malloc(out_len + 1);
    if (!out) return NULL;

    // Second pass: build output
    char *dst = out;
    p = tmpl;
    while (*p) {
        if (p[0] == '{' && p[1] == '{') {
            const char *end = strstr(p + 2, "}}");
            if (end) {
                int klen = (int)(end - p - 2);
                bool found = false;
                for (int i = 0; i < count; i++) {
                    if ((int)strlen(keys[i]) == klen && strncmp(p + 2, keys[i], klen) == 0) {
                        int vlen = strlen(vals[i]);
                        memcpy(dst, vals[i], vlen);
                        dst += vlen;
                        p = end + 2;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    *dst++ = *p++;
                }
                continue;
            }
        }
        *dst++ = *p++;
    }
    *dst = '\0';
    return out;
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

    const char *keys[] = { "bg", "status_bg", "fg", "fg_dim", "accent" };
    const char *vals[] = { bg, status_bg, fg, fg_dim, accent };

    char *result = substitute(tmpl, keys, vals, 5);
    free(tmpl);
    return result;
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
