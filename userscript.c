#include "userscript.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fnmatch.h>
#include <sys/stat.h>

static const char *kDefaultOldReddit =
#include "old-reddit_js.inc"
;

static const char *kDefaultYouTubeAdblock =
#include "youtube-adblock_js.inc"
;

static const char *kDefaultDarkMode =
#include "dark-mode_js.inc"
;

void userscript_init(UserScriptManager *m) {
    memset(m, 0, sizeof(*m));
}

void userscript_free(UserScriptManager *m) {
    for (int i = 0; i < m->count; i++) {
        free(m->scripts[i].source);
        m->scripts[i].source = NULL;
    }
    m->count = 0;
}

static char *read_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (len < 0) { fclose(f); return NULL; }

    char *buf = malloc(len + 1);
    if (!buf) { fclose(f); return NULL; }

    size_t read = fread(buf, 1, len, f);
    buf[read] = '\0';
    fclose(f);
    return buf;
}

static void parse_header(UserScript *script, const char *source) {
    /* defaults */
    script->name[0] = '\0';
    script->match_count = 0;
    script->run_at = SCRIPT_RUN_AT_DOCUMENT_END;

    const char *start = strstr(source, "// ==UserScript==");
    const char *end = strstr(source, "// ==/UserScript==");
    if (!start || !end || end <= start) return;

    const char *p = start;
    while (p < end) {
        /* advance to next line */
        const char *nl = strchr(p, '\n');
        if (!nl || nl >= end) break;
        p = nl + 1;

        /* skip whitespace and "//" prefix */
        const char *line = p;
        while (line < end && (*line == ' ' || *line == '\t')) line++;
        if (line + 2 < end && line[0] == '/' && line[1] == '/') {
            line += 2;
            while (line < end && *line == ' ') line++;
        } else {
            continue;
        }

        /* find end of this line */
        const char *eol = strchr(line, '\n');
        if (!eol || eol > end) eol = end;

        if (strncmp(line, "@name", 5) == 0 && (line[5] == ' ' || line[5] == '\t')) {
            const char *val = line + 5;
            while (val < eol && *val == ' ') val++;
            size_t len = eol - val;
            if (len >= sizeof(script->name)) len = sizeof(script->name) - 1;
            memcpy(script->name, val, len);
            /* trim trailing whitespace */
            while (len > 0 && (script->name[len-1] == ' ' || script->name[len-1] == '\r'))
                len--;
            script->name[len] = '\0';
        } else if (strncmp(line, "@match", 6) == 0 && (line[6] == ' ' || line[6] == '\t')) {
            if (script->match_count < MAX_MATCH_PATTERNS) {
                const char *val = line + 6;
                while (val < eol && *val == ' ') val++;
                size_t len = eol - val;
                if (len >= sizeof(script->match[0])) len = sizeof(script->match[0]) - 1;
                memcpy(script->match[script->match_count], val, len);
                while (len > 0 && (script->match[script->match_count][len-1] == ' '
                       || script->match[script->match_count][len-1] == '\r'))
                    len--;
                script->match[script->match_count][len] = '\0';
                script->match_count++;
            }
        } else if (strncmp(line, "@run-at", 7) == 0) {
            const char *val = line + 7;
            while (val < eol && *val == ' ') val++;
            if (strncmp(val, "document-start", 14) == 0) {
                script->run_at = SCRIPT_RUN_AT_DOCUMENT_START;
            } else {
                script->run_at = SCRIPT_RUN_AT_DOCUMENT_END;
            }
        }
    }
}

static bool match_pattern(const char *pattern, const char *url) {
    /* special case: <all_urls> */
    if (strcmp(pattern, "<all_urls>") == 0) return true;

    /* parse pattern: scheme://host/path */
    const char *sep = strstr(pattern, "://");
    if (!sep) return false;

    size_t scheme_len = sep - pattern;
    char scheme_pat[32];
    if (scheme_len >= sizeof(scheme_pat)) return false;
    memcpy(scheme_pat, pattern, scheme_len);
    scheme_pat[scheme_len] = '\0';

    const char *host_start = sep + 3;
    const char *slash = strchr(host_start, '/');
    char host_pat[256];
    char path_pat[256];

    if (slash) {
        size_t hlen = slash - host_start;
        if (hlen >= sizeof(host_pat)) return false;
        memcpy(host_pat, host_start, hlen);
        host_pat[hlen] = '\0';
        snprintf(path_pat, sizeof(path_pat), "%s", slash);
    } else {
        snprintf(host_pat, sizeof(host_pat), "%s", host_start);
        strcpy(path_pat, "/");
    }

    /* parse URL: scheme://host/path */
    const char *url_sep = strstr(url, "://");
    if (!url_sep) return false;

    size_t url_scheme_len = url_sep - url;
    char url_scheme[32];
    if (url_scheme_len >= sizeof(url_scheme)) return false;
    memcpy(url_scheme, url, url_scheme_len);
    url_scheme[url_scheme_len] = '\0';

    const char *url_host_start = url_sep + 3;
    const char *url_slash = strchr(url_host_start, '/');
    char url_host[256];
    char url_path[2048];

    if (url_slash) {
        size_t hlen = url_slash - url_host_start;
        if (hlen >= sizeof(url_host)) return false;
        memcpy(url_host, url_host_start, hlen);
        url_host[hlen] = '\0';
        snprintf(url_path, sizeof(url_path), "%s", url_slash);
    } else {
        snprintf(url_host, sizeof(url_host), "%s", url_host_start);
        strcpy(url_path, "/");
    }

    /* match scheme (* matches http and https) */
    if (strcmp(scheme_pat, "*") == 0) {
        if (strcmp(url_scheme, "http") != 0 && strcmp(url_scheme, "https") != 0)
            return false;
    } else {
        if (strcmp(scheme_pat, url_scheme) != 0) return false;
    }

    /* match host */
    if (fnmatch(host_pat, url_host, 0) != 0) return false;

    /* match path */
    if (fnmatch(path_pat, url_path, 0) != 0) return false;

    return true;
}

bool userscript_matches_url(const UserScript *script, const char *url) {
    for (int i = 0; i < script->match_count; i++) {
        if (match_pattern(script->match[i], url))
            return true;
    }
    return false;
}

int userscript_load_dir(UserScriptManager *m, const char *dir_path) {
    DIR *dir = opendir(dir_path);
    if (!dir) return 0;

    int loaded = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        if (m->count >= MAX_USERSCRIPTS) break;
        if (ent->d_type != DT_REG && ent->d_type != DT_UNKNOWN) continue;

        const char *name = ent->d_name;
        size_t nlen = strlen(name);

        /* must end in .js */
        if (nlen < 4 || strcmp(name + nlen - 3, ".js") != 0) continue;

        /* skip .js.disabled */
        if (nlen >= 12 && strcmp(name + nlen - 12, ".js.disabled") == 0) continue;

        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", dir_path, name);

        char *source = read_file(path);
        if (!source) continue;

        /* skip internal scripts (SwimScript header) — they are invoked on demand */
        if (strstr(source, "// ==SwimScript==")) { free(source); continue; }

        UserScript *script = &m->scripts[m->count];
        memset(script, 0, sizeof(*script));
        parse_header(script, source);

        /* use filename as fallback name */
        if (script->name[0] == '\0') {
            snprintf(script->name, sizeof(script->name), "%s", name);
        }

        script->source = source;
        snprintf(script->filepath, sizeof(script->filepath), "%s", path);

        m->count++;
        loaded++;
    }

    closedir(dir);
    return loaded;
}

bool userscript_create_defaults(const char *dir_path) {
    struct stat st;
    if (stat(dir_path, &st) == 0) return true; /* already exists */

    /* create directory (and parent if needed) */
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", dir_path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0700);
            *p = '/';
        }
    }
    if (mkdir(tmp, 0700) != 0 && stat(tmp, &st) != 0) return false;

    /* write old-reddit.js */
    char path[1024];
    snprintf(path, sizeof(path), "%s/old-reddit.js", dir_path);
    FILE *f = fopen(path, "w");
    if (f) {
        fputs(kDefaultOldReddit, f);
        fclose(f);
    }

    /* write youtube-adblock.js */
    snprintf(path, sizeof(path), "%s/youtube-adblock.js", dir_path);
    f = fopen(path, "w");
    if (f) {
        fputs(kDefaultYouTubeAdblock, f);
        fclose(f);
    }

    /* write dark-mode.js.disabled (opt-in) */
    snprintf(path, sizeof(path), "%s/dark-mode.js.disabled", dir_path);
    f = fopen(path, "w");
    if (f) {
        fputs(kDefaultDarkMode, f);
        fclose(f);
    }

    return true;
}
