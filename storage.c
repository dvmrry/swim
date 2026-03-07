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
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/.config/swim", home);
    mkdir(path, 0755);
}

void storage_init(Storage *s, const char *filepath) {
    memset(s, 0, sizeof(*s));
    s->capacity = INITIAL_CAP;
    s->entries = calloc(INITIAL_CAP, sizeof(StorageEntry));
    snprintf(s->filepath, sizeof(s->filepath), "%s", filepath);
}

// Simple JSON writing — no dependency needed for this format
void storage_save(Storage *s) {
    FILE *f = fopen(s->filepath, "w");
    if (!f) return;

    fprintf(f, "[\n");
    for (int i = 0; i < s->count; i++) {
        StorageEntry *e = &s->entries[i];
        // Escape quotes in title
        char escaped_title[512];
        int j = 0;
        for (int k = 0; e->title[k] && j < 510; k++) {
            if (e->title[k] == '"' || e->title[k] == '\\') {
                escaped_title[j++] = '\\';
            }
            escaped_title[j++] = e->title[k];
        }
        escaped_title[j] = '\0';

        fprintf(f, "  {\"url\":\"%s\",\"title\":\"%s\",\"time\":%ld}%s\n",
            e->url, escaped_title, e->timestamp,
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
    fread(buf, 1, len, f);
    buf[len] = '\0';
    fclose(f);

    // Parse entries: find "url":"...", "title":"...", "time":...
    char *p = buf;
    while ((p = strstr(p, "\"url\":\""))) {
        if (s->count >= s->capacity) {
            s->capacity *= 2;
            if (s->capacity > MAX_ENTRIES) s->capacity = MAX_ENTRIES;
            s->entries = realloc(s->entries, s->capacity * sizeof(StorageEntry));
        }
        if (s->count >= MAX_ENTRIES) break;

        StorageEntry *e = &s->entries[s->count];
        memset(e, 0, sizeof(*e));

        // Extract URL
        p += 7;  // skip "url":"
        int i = 0;
        while (*p && *p != '"' && i < 2047) {
            e->url[i++] = *p++;
        }
        e->url[i] = '\0';

        // Extract title
        char *t = strstr(p, "\"title\":\"");
        if (t) {
            t += 9;
            i = 0;
            while (*t && i < 255) {
                if (*t == '\\' && *(t+1)) { t++; }
                if (*t == '"') break;
                e->title[i++] = *t++;
            }
            e->title[i] = '\0';
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
            s->capacity *= 2;
            s->entries = realloc(s->entries, s->capacity * sizeof(StorageEntry));
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
        fprintf(f, "  \"%s\"%s\n", urls[i], (i < count - 1) ? "," : "");
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
    fread(buf, 1, len, f);
    buf[len] = '\0';
    fclose(f);

    int count = 0;
    char *p = buf;
    while (count < max_urls && (p = strchr(p, '"'))) {
        p++;  // skip opening quote
        int i = 0;
        while (*p && *p != '"' && i < 2047) {
            urls[count][i++] = *p++;
        }
        urls[count][i] = '\0';
        if (i > 0) count++;
        if (*p == '"') p++;
    }

    free(buf);
    return count;
}

void storage_free(Storage *s) {
    free(s->entries);
    memset(s, 0, sizeof(*s));
}
