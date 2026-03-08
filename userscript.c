#include "userscript.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <fnmatch.h>
#include <sys/stat.h>

static const char *kDefaultOldReddit =
    "// ==UserScript==\n"
    "// @name        Old Reddit Cleanup\n"
    "// @match       *://old.reddit.com/*\n"
    "// @run-at      document-start\n"
    "// ==/UserScript==\n"
    "\n"
    "(function(){\n"
    "var s=document.createElement('style');\n"
    "s.textContent='\\\n"
    ".sponsorlink,.promoted,.promotedlink{display:none!important}\\\n"
    "#siteTable_organic{display:none!important}\\\n"
    ".infobar.listingsignupbar{display:none!important}\\\n"
    ".premium-banner-outer,.goldvertisement,.ad-container{display:none!important}\\\n"
    ".spacer .premium-banner,.spacer .gold-accent{display:none!important}\\\n"
    ".side{overflow:hidden}\\\n"
    ".side.swim-hidden{width:0!important;opacity:0;padding:0!important;margin:0!important}\\\n"
    ".side.swim-animate,.side.swim-animate~.content,.side.swim-animate+.content{transition:all 0.2s}\\\n"
    ".side.swim-hidden~.content,.side.swim-hidden+.content{margin-right:20px!important}\\\n"
    "';\n"
    "(document.head||document.documentElement).appendChild(s);\n"
    "try{if(localStorage.getItem('swim-sidebar-hidden')==='1'){\n"
    "document.documentElement.classList.add('swim-sidebar-will-hide');\n"
    "s.textContent+='.swim-sidebar-will-hide .side{width:0!important;opacity:0;padding:0!important;margin:0!important}'\n"
    "+'.swim-sidebar-will-hide .content{margin-right:20px!important}';\n"
    "}}catch(e){}\n"
    "\n"
    "document.addEventListener('click',function(e){\n"
    "if(e.target.id!=='swim-sidebar-btn')return;\n"
    "e.stopPropagation();\n"
    "var s=document.querySelector('.side');\n"
    "if(!s)return;\n"
    "document.documentElement.classList.remove('swim-sidebar-will-hide');\n"
    "s.classList.add('swim-animate');\n"
    "s.classList.toggle('swim-hidden');\n"
    "var h=s.classList.contains('swim-hidden');\n"
    "e.target.textContent=h?'\\u00BB':'\\u00AB';\n"
    "localStorage.setItem('swim-sidebar-hidden',h?'1':'0');\n"
    "});\n"
    "\n"
    "function setup(){\n"
    "if(document.getElementById('swim-sidebar-btn'))return true;\n"
    "var side=document.querySelector('.side');\n"
    "if(!side)return false;\n"
    "var hidden=localStorage.getItem('swim-sidebar-hidden')==='1';\n"
    "if(hidden){side.classList.add('swim-hidden')}\n"
    "var btn=document.createElement('div');\n"
    "btn.id='swim-sidebar-btn';\n"
    "btn.textContent=hidden?'\\u00BB':'\\u00AB';\n"
    "btn.style.cssText='position:fixed;right:16px;top:50%;transform:translateY(-50%);'\n"
    "+'z-index:9999;cursor:pointer;font-size:16px;color:#666;background:#1a1a1a;'\n"
    "+'border:1px solid #333;border-radius:4px;padding:12px 6px;'\n"
    "+'user-select:none;opacity:0;transition:opacity 0.3s';\n"
    "setTimeout(function(){btn.style.opacity='1'},100);\n"
    "btn.title='Toggle sidebar';\n"
    "document.body.appendChild(btn);\n"
    "return true;\n"
    "}\n"
    "\n"
    "if(document.readyState==='loading'){\n"
    "document.addEventListener('DOMContentLoaded',function(){if(!setup()){var n=0;var iv=setInterval(function(){if(setup()||++n>=20)clearInterval(iv)},250);}});\n"
    "}else{\n"
    "if(!setup()){var n=0;var iv=setInterval(function(){if(setup()||++n>=20)clearInterval(iv)},250);}\n"
    "}\n"
    "})();\n";

static const char *kDefaultYouTubeAdblock =
    "// ==UserScript==\n"
    "// @name        YouTube Ad Blocker\n"
    "// @match       *://www.youtube.com/*\n"
    "// @match       *://m.youtube.com/*\n"
    "// @run-at      document-end\n"
    "// ==/UserScript==\n"
    "\n"
    "(function(){\n"
    "var s=document.createElement('style');\n"
    "s.textContent='\\\n"
    ".ad-showing .video-ads,\\\n"
    ".ytp-ad-module,\\\n"
    ".ytp-ad-overlay-container,\\\n"
    ".ytp-ad-text-overlay,\\\n"
    ".ytd-promoted-sparkles-web-renderer,\\\n"
    ".ytd-display-ad-renderer,\\\n"
    ".ytd-companion-slot-renderer,\\\n"
    ".ytd-action-companion-ad-renderer,\\\n"
    ".ytd-in-feed-ad-layout-renderer,\\\n"
    ".ytd-ad-slot-renderer,\\\n"
    ".ytd-banner-promo-renderer,\\\n"
    ".ytd-statement-banner-renderer,\\\n"
    ".ytd-masthead-ad-renderer,\\\n"
    "#player-ads,\\\n"
    "#masthead-ad,\\\n"
    ".ytd-merch-shelf-renderer,\\\n"
    ".ytd-engagement-panel-section-list-renderer[target-id=engagement-panel-ads]\\\n"
    "{display:none!important}';\n"
    "document.head.appendChild(s);\n"
    "\n"
    "var observer=new MutationObserver(function(){\n"
    "var skip=document.querySelector('.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad-button');\n"
    "if(skip){skip.click();return}\n"
    "var v=document.querySelector('.ad-showing video');\n"
    "if(v&&v.duration&&v.duration>0){v.currentTime=v.duration}\n"
    "});\n"
    "observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});\n"
    "})();\n";

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
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && stat(tmp, &st) != 0) return false;

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

    return true;
}
