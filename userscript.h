#ifndef SWIM_USERSCRIPT_H
#define SWIM_USERSCRIPT_H

#include <stdbool.h>

#define MAX_USERSCRIPTS 64
#define MAX_MATCH_PATTERNS 16

typedef enum {
    SCRIPT_RUN_AT_DOCUMENT_END,
    SCRIPT_RUN_AT_DOCUMENT_START,
} ScriptRunAt;

typedef struct {
    char name[128];
    char match[MAX_MATCH_PATTERNS][256];
    int match_count;
    ScriptRunAt run_at;
    char *source;
    char filepath[512];
} UserScript;

typedef struct {
    UserScript scripts[MAX_USERSCRIPTS];
    int count;
} UserScriptManager;

void userscript_init(UserScriptManager *m);
void userscript_free(UserScriptManager *m);
int userscript_load_dir(UserScriptManager *m, const char *dir_path);
bool userscript_matches_url(const UserScript *script, const char *url);
bool userscript_create_defaults(const char *dir_path);

#endif
