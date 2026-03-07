#include "storage.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <ctype.h>

#define INITIAL_CAP 256

void storage_ensure_dir(void) {
    const char *home = getenv("HOME");
    if (!home) return;

    char path[512];
    snprintf(path, sizeof(path), "%s/.config", home);
    mkdir(path, 0700);
    snprintf(path, sizeof(path), "%s/.config/swim", home);
    mkdir(path, 0700);
    snprintf(path, sizeof(path), "%s/.config/swim/profiles", home);
    mkdir(path, 0700);
}

void storage_init(Storage *s, const char *filepath) {
    memset(s, 0, sizeof(*s));
    s->capacity = INITIAL_CAP;
    s->entries = calloc(INITIAL_CAP, sizeof(StorageEntry));
    if (!s->entries) { s->capacity = 0; return; }
    snprintf(s->filepath, sizeof(s->filepath), "%s", filepath);
}

// Escape a string for JSON: quotes, backslashes, and control characters
static int json_escape(const char *src, char *dst, int dst_size) {
    int j = 0;
    for (int k = 0; src[k] && j < dst_size - 6; k++) {
        unsigned char c = (unsigned char)src[k];
        if (c == '"' || c == '\\') {
            dst[j++] = '\\'; dst[j++] = c;
        } else if (c == '\n') {
            dst[j++] = '\\'; dst[j++] = 'n';
        } else if (c == '\r') {
            dst[j++] = '\\'; dst[j++] = 'r';
        } else if (c == '\t') {
            dst[j++] = '\\'; dst[j++] = 't';
        } else if (c < 0x20) {
            j += snprintf(dst + j, dst_size - j, "\\u%04x", c);
        } else {
            dst[j++] = c;
        }
    }
    dst[j] = '\0';
    return j;
}

// Unescape a JSON string in-place: write unescaped chars into dst, return length.
// Handles \", \\, \n, \r, \t, \/, \uXXXX (BMP only, to UTF-8).
static int json_unescape(const char *src, const char *end, char *dst, int dst_size) {
    int j = 0;
    while (src < end && j < dst_size - 4) {  // -4 for worst case UTF-8
        if (*src == '\\' && src + 1 < end) {
            src++;
            switch (*src) {
            case '"':  dst[j++] = '"'; break;
            case '\\': dst[j++] = '\\'; break;
            case '/':  dst[j++] = '/'; break;
            case 'n':  dst[j++] = '\n'; break;
            case 'r':  dst[j++] = '\r'; break;
            case 't':  dst[j++] = '\t'; break;
            case 'u':
                if (src + 4 < end) {
                    unsigned int cp = 0;
                    if (sscanf(src + 1, "%4x", &cp) == 1) {
                        src += 4;
                        if (cp < 0x80) {
                            dst[j++] = (char)cp;
                        } else if (cp < 0x800) {
                            dst[j++] = (char)(0xC0 | (cp >> 6));
                            dst[j++] = (char)(0x80 | (cp & 0x3F));
                        } else {
                            dst[j++] = (char)(0xE0 | (cp >> 12));
                            dst[j++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                            dst[j++] = (char)(0x80 | (cp & 0x3F));
                        }
                    } else {
                        dst[j++] = 'u';  // malformed, keep literal
                    }
                } else {
                    dst[j++] = 'u';
                }
                break;
            default: dst[j++] = *src; break;
            }
            src++;
        } else {
            dst[j++] = *src++;
        }
    }
    dst[j] = '\0';
    return j;
}

// Find the end of a JSON string starting after the opening quote.
// Handles escaped quotes. Returns pointer to closing quote, or NULL.
static const char *json_string_end(const char *p) {
    while (*p) {
        if (*p == '"') return p;
        if (*p == '\\' && *(p + 1)) p++;  // skip escaped char
        p++;
    }
    return NULL;
}

// Simple JSON writing — no dependency needed for this format
void storage_save(Storage *s) {
    FILE *f = fopen(s->filepath, "w");
    if (!f) return;

    fprintf(f, "[\n");
    for (int i = 0; i < s->count; i++) {
        StorageEntry *e = &s->entries[i];
        char escaped_url[4096];
        json_escape(e->url, escaped_url, sizeof(escaped_url));

        char escaped_title[512];
        json_escape(e->title, escaped_title, sizeof(escaped_title));

        fprintf(f, "  {\"url\":\"%s\",\"title\":\"%s\",\"time\":%ld}%s\n",
            escaped_url, escaped_title, e->timestamp,
            (i < s->count - 1) ? "," : "");
    }
    fprintf(f, "]\n");
    fclose(f);
}

// Minimal JSON parser — just enough for our format
void storage_load(Storage *s) {
    FILE *f = fopen(s->filepath, "r");
    if (!f) return;

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);

    char *buf = malloc(len + 1);
    if (!buf) { fclose(f); return; }
    fread(buf, 1, len, f);
    buf[len] = '\0';
    fclose(f);

    // Parse entries: find "url":"...", "title":"...", "time":...
    char *p = buf;
    while ((p = strstr(p, "\"url\":\""))) {
        if (s->count >= s->capacity) {
            int new_cap = s->capacity * 2;
            if (new_cap > MAX_ENTRIES) new_cap = MAX_ENTRIES;
            StorageEntry *tmp = realloc(s->entries, new_cap * sizeof(StorageEntry));
            if (!tmp) break;
            s->entries = tmp;
            s->capacity = new_cap;
        }
        if (s->count >= MAX_ENTRIES) break;

        StorageEntry *e = &s->entries[s->count];
        memset(e, 0, sizeof(*e));

        // Extract URL
        p += 7;  // skip "url":"
        const char *url_end = json_string_end(p);
        if (!url_end) break;
        json_unescape(p, url_end, e->url, sizeof(e->url));
        p = (char *)url_end + 1;

        // Extract title
        char *t = strstr(p, "\"title\":\"");
        if (t) {
            t += 9;
            const char *title_end = json_string_end(t);
            if (title_end) {
                json_unescape(t, title_end, e->title, sizeof(e->title));
            }
        }

        // Extract time
        char *tm = strstr(p, "\"time\":");
        if (tm) {
            tm += 7;
            e->timestamp = atol(tm);
        }

        s->count++;
    }

    free(buf);
}

void storage_add(Storage *s, const char *url, const char *title) {
    if (!url || !url[0]) return;

    // Check for duplicate (update if exists)
    for (int i = 0; i < s->count; i++) {
        if (strcmp(s->entries[i].url, url) == 0) {
            if (title) snprintf(s->entries[i].title, sizeof(s->entries[i].title), "%s", title);
            s->entries[i].timestamp = time(NULL);
            return;
        }
    }

    if (s->count >= s->capacity) {
        if (s->capacity >= MAX_ENTRIES) {
            // Drop oldest entry
            memmove(&s->entries[0], &s->entries[1], (s->count - 1) * sizeof(StorageEntry));
            s->count--;
        } else {
            int new_cap = s->capacity * 2;
            StorageEntry *tmp = realloc(s->entries, new_cap * sizeof(StorageEntry));
            if (!tmp) return;
            s->entries = tmp;
            s->capacity = new_cap;
        }
    }

    StorageEntry *e = &s->entries[s->count++];
    memset(e, 0, sizeof(*e));
    snprintf(e->url, sizeof(e->url), "%s", url);
    if (title) snprintf(e->title, sizeof(e->title), "%s", title);
    e->timestamp = time(NULL);
}

// Simple substring fuzzy match
static bool fuzzy_match(const char *haystack, const char *needle) {
    if (!needle || !needle[0]) return true;

    int ni = 0;
    int nlen = strlen(needle);
    for (int i = 0; haystack[i] && ni < nlen; i++) {
        if (tolower((unsigned char)haystack[i]) == tolower((unsigned char)needle[ni])) {
            ni++;
        }
    }
    return ni == nlen;
}

int storage_search(Storage *s, const char *query, int *results, int max_results) {
    int found = 0;
    // Search most recent first
    for (int i = s->count - 1; i >= 0 && found < max_results; i--) {
        if (fuzzy_match(s->entries[i].url, query) ||
            fuzzy_match(s->entries[i].title, query)) {
            results[found++] = i;
        }
    }
    return found;
}

// --- Session ---

void session_save(const char *filepath, const char **urls, int count) {
    FILE *f = fopen(filepath, "w");
    if (!f) return;
    fprintf(f, "[\n");
    for (int i = 0; i < count; i++) {
        char escaped[4096];
        json_escape(urls[i], escaped, sizeof(escaped));
        fprintf(f, "  \"%s\"%s\n", escaped, (i < count - 1) ? "," : "");
    }
    fprintf(f, "]\n");
    fclose(f);
}

int session_load(const char *filepath, char urls[][2048], int max_urls) {
    FILE *f = fopen(filepath, "r");
    if (!f) return 0;

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);

    char *buf = malloc(len + 1);
    if (!buf) { fclose(f); return 0; }
    fread(buf, 1, len, f);
    buf[len] = '\0';
    fclose(f);

    int count = 0;
    char *p = buf;
    while (count < max_urls && (p = strchr(p, '"'))) {
        p++;  // skip opening quote
        const char *end = json_string_end(p);
        if (!end) break;
        int len = json_unescape(p, end, urls[count], 2048);
        if (len > 0) count++;
        p = (char *)end + 1;
    }

    free(buf);
    return count;
}

void storage_free(Storage *s) {
    free(s->entries);
    memset(s, 0, sizeof(*s));
}
