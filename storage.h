#ifndef SWIM_STORAGE_H
#define SWIM_STORAGE_H

#include <stdbool.h>
#include <time.h>

#define MAX_ENTRIES 4096

typedef struct StorageEntry {
    char url[2048];
    char title[256];
    time_t timestamp;
} StorageEntry;

typedef struct Storage {
    StorageEntry *entries;
    int count;
    int capacity;
    char filepath[512];
} Storage;

void storage_init(Storage *s, const char *filepath);
void storage_add(Storage *s, const char *url, const char *title);
void storage_load(Storage *s);
void storage_save(Storage *s);
void storage_free(Storage *s);

// Fuzzy search — returns indices of matches, caller provides output array
// Returns number of matches
int storage_search(Storage *s, const char *query, int *results, int max_results);

// Ensure ~/.config/swim/ exists
void storage_ensure_dir(void);

// Session: save/load list of URLs
// save_session writes URLs, load_session reads them into caller-provided array
// Returns count of loaded URLs
void session_save(const char *filepath, const char **urls, int count);
int  session_load(const char *filepath, char urls[][2048], int max_urls);

#endif
