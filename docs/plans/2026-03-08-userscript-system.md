# Userscript System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Load site-specific JS from `~/.config/swim/scripts/` with Greasemonkey headers, replacing hardcoded site scripts.

**Architecture:** New `userscript.c/h` handles parsing and loading. `ui.m` receives an array of loaded scripts and injects matching ones into each new webview. Old Reddit and YouTube scripts move to default files created on first run. Core scripts (focus, hints) stay compiled in.

**Tech Stack:** C (parser/loader), Objective-C (WKUserScript injection), Greasemonkey `@match` pattern matching

---

### Task 1: Userscript Parser and Loader

Create `userscript.h` and `userscript.c` — the header parser, match pattern checker, and directory scanner.

**Files:**
- Create: `userscript.h`
- Create: `userscript.c`

**Step 1: Create `userscript.h`**

```c
#ifndef SWIM_USERSCRIPT_H
#define SWIM_USERSCRIPT_H

#include <stdbool.h>

#define MAX_USERSCRIPTS 64
#define MAX_MATCH_PATTERNS 16

typedef enum {
    SCRIPT_RUN_AT_DOCUMENT_END,   // default
    SCRIPT_RUN_AT_DOCUMENT_START,
} ScriptRunAt;

typedef struct {
    char name[128];
    char match[MAX_MATCH_PATTERNS][256];  // @match patterns
    int match_count;
    ScriptRunAt run_at;
    char *source;       // full file contents (malloc'd)
    char filepath[512]; // for display in :scripts
} UserScript;

typedef struct {
    UserScript scripts[MAX_USERSCRIPTS];
    int count;
} UserScriptManager;

// Init manager (zeroes everything)
void userscript_init(UserScriptManager *m);

// Free all loaded script sources
void userscript_free(UserScriptManager *m);

// Load all .js files from directory. Returns number loaded.
int userscript_load_dir(UserScriptManager *m, const char *dir_path);

// Check if a URL matches a script's @match patterns
bool userscript_matches_url(const UserScript *script, const char *url);

// Create default scripts directory with bundled scripts.
// Only creates if dir doesn't exist. Returns true if created.
bool userscript_create_defaults(const char *dir_path);

#endif
```

**Step 2: Create `userscript.c`**

```c
#include "userscript.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <fnmatch.h>

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

// Read entire file into malloc'd string. Returns NULL on failure.
static char *read_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len <= 0) { fclose(f); return NULL; }
    char *buf = malloc(len + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t read = fread(buf, 1, len, f);
    buf[read] = '\0';
    fclose(f);
    return buf;
}

// Parse Greasemonkey header from script source.
// Looks for // ==UserScript== ... // ==/UserScript== block.
static void parse_header(UserScript *script) {
    const char *src = script->source;
    const char *start = strstr(src, "// ==UserScript==");
    const char *end = strstr(src, "// ==/UserScript==");
    if (!start || !end || end <= start) return;

    // Default name from filename if not specified
    // (already set before calling this)

    const char *line = start;
    while (line < end) {
        // Skip to next line
        const char *eol = strchr(line, '\n');
        if (!eol) break;

        // Trim leading whitespace and "//"
        const char *p = line;
        while (p < eol && (*p == ' ' || *p == '\t' || *p == '/')) p++;

        if (strncmp(p, "@name", 5) == 0) {
            p += 5;
            while (p < eol && (*p == ' ' || *p == '\t')) p++;
            int len = (int)(eol - p);
            if (len > 0 && len < (int)sizeof(script->name)) {
                // Trim trailing whitespace
                while (len > 0 && (p[len-1] == ' ' || p[len-1] == '\t' || p[len-1] == '\r')) len--;
                memcpy(script->name, p, len);
                script->name[len] = '\0';
            }
        } else if (strncmp(p, "@match", 6) == 0) {
            p += 6;
            while (p < eol && (*p == ' ' || *p == '\t')) p++;
            int len = (int)(eol - p);
            if (len > 0 && script->match_count < MAX_MATCH_PATTERNS) {
                while (len > 0 && (p[len-1] == ' ' || p[len-1] == '\t' || p[len-1] == '\r')) len--;
                if (len < (int)sizeof(script->match[0])) {
                    memcpy(script->match[script->match_count], p, len);
                    script->match[script->match_count][len] = '\0';
                    script->match_count++;
                }
            }
        } else if (strncmp(p, "@run-at", 7) == 0) {
            p += 7;
            while (p < eol && (*p == ' ' || *p == '\t')) p++;
            if (strncmp(p, "document-start", 14) == 0) {
                script->run_at = SCRIPT_RUN_AT_DOCUMENT_START;
            }
            // default is DOCUMENT_END, no need to check
        }

        line = eol + 1;
    }
}

// Match a URL against a single @match pattern.
// Pattern format: scheme://host/path where * is wildcard.
// Examples: *://old.reddit.com/*, *://*.youtube.com/*
static bool match_pattern(const char *pattern, const char *url) {
    // Special case: <all_urls> or *
    if (strcmp(pattern, "<all_urls>") == 0 || strcmp(pattern, "*") == 0) return true;

    // Split pattern into scheme, host, path at "://" and first "/" after host
    const char *scheme_end = strstr(pattern, "://");
    if (!scheme_end) return false;

    char scheme_pat[16], host_pat[256], path_pat[256];
    int scheme_len = (int)(scheme_end - pattern);
    if (scheme_len >= (int)sizeof(scheme_pat)) return false;
    memcpy(scheme_pat, pattern, scheme_len);
    scheme_pat[scheme_len] = '\0';

    const char *host_start = scheme_end + 3;
    const char *path_start = strchr(host_start, '/');
    if (!path_start) {
        snprintf(host_pat, sizeof(host_pat), "%s", host_start);
        snprintf(path_pat, sizeof(path_pat), "/");
    } else {
        int host_len = (int)(path_start - host_start);
        if (host_len >= (int)sizeof(host_pat)) return false;
        memcpy(host_pat, host_start, host_len);
        host_pat[host_len] = '\0';
        snprintf(path_pat, sizeof(path_pat), "%s", path_start);
    }

    // Split URL the same way
    const char *url_scheme_end = strstr(url, "://");
    if (!url_scheme_end) return false;

    char url_scheme[16], url_host[256], url_path[256];
    int url_scheme_len = (int)(url_scheme_end - url);
    if (url_scheme_len >= (int)sizeof(url_scheme)) return false;
    memcpy(url_scheme, url, url_scheme_len);
    url_scheme[url_scheme_len] = '\0';

    const char *url_host_start = url_scheme_end + 3;
    const char *url_path_start = strchr(url_host_start, '/');
    if (!url_path_start) {
        snprintf(url_host, sizeof(url_host), "%s", url_host_start);
        snprintf(url_path, sizeof(url_path), "/");
    } else {
        int url_host_len = (int)(url_path_start - url_host_start);
        if (url_host_len >= (int)sizeof(url_host)) return false;
        memcpy(url_host, url_host_start, url_host_len);
        url_host[url_host_len] = '\0';
        snprintf(url_path, sizeof(url_path), "%s", url_path_start);
    }

    // Match scheme (* matches any)
    if (strcmp(scheme_pat, "*") != 0 && strcmp(scheme_pat, url_scheme) != 0) return false;

    // Match host (fnmatch handles * and *.example.com)
    if (fnmatch(host_pat, url_host, 0) != 0) return false;

    // Match path
    if (fnmatch(path_pat, url_path, 0) != 0) return false;

    return true;
}

bool userscript_matches_url(const UserScript *script, const char *url) {
    for (int i = 0; i < script->match_count; i++) {
        if (match_pattern(script->match[i], url)) return true;
    }
    return false;
}

int userscript_load_dir(UserScriptManager *m, const char *dir_path) {
    userscript_free(m);

    DIR *dir = opendir(dir_path);
    if (!dir) return 0;

    struct dirent *entry;
    while ((entry = readdir(dir)) && m->count < MAX_USERSCRIPTS) {
        const char *name = entry->d_name;
        int len = (int)strlen(name);

        // Only load .js files (skip .js.disabled)
        if (len < 4 || strcmp(name + len - 3, ".js") != 0) continue;

        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", dir_path, name);

        char *source = read_file(path);
        if (!source) continue;

        UserScript *s = &m->scripts[m->count];
        memset(s, 0, sizeof(*s));
        s->source = source;
        s->run_at = SCRIPT_RUN_AT_DOCUMENT_END;
        snprintf(s->filepath, sizeof(s->filepath), "%s", path);

        // Default name from filename (strip .js)
        int name_len = len - 3;
        if (name_len >= (int)sizeof(s->name)) name_len = (int)sizeof(s->name) - 1;
        memcpy(s->name, name, name_len);
        s->name[name_len] = '\0';

        parse_header(s);
        m->count++;
    }

    closedir(dir);
    return m->count;
}

// --- Default script content ---

static const char *kDefaultOldReddit =
    "// ==UserScript==\n"
    "// @name        Old Reddit Cleanup\n"
    "// @match       *://old.reddit.com/*\n"
    "// @run-at      document-start\n"
    "// ==/UserScript==\n"
    "\n"
    "// --- Early CSS (runs at document-start to prevent flash) ---\n"
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
    "// --- Sidebar toggle (also runs at document-start, but waits for DOM) ---\n"
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

bool userscript_create_defaults(const char *dir_path) {
    struct stat st;
    if (stat(dir_path, &st) == 0) return false;  // already exists

    mkdir(dir_path, 0755);

    char path[1024];

    snprintf(path, sizeof(path), "%s/old-reddit.js", dir_path);
    FILE *f = fopen(path, "w");
    if (f) { fputs(kDefaultOldReddit, f); fclose(f); }

    snprintf(path, sizeof(path), "%s/youtube-adblock.js", dir_path);
    f = fopen(path, "w");
    if (f) { fputs(kDefaultYouTubeAdblock, f); fclose(f); }

    return true;
}
```

**Step 3: Verify it compiles**

Run: `make`
Expected: Build succeeds (after adding to Makefile in next task).

**Step 4: Commit**

```bash
git add userscript.h userscript.c
git commit -m "Add userscript parser and loader"
```

---

### Task 2: Integrate into Build and UI

Wire the userscript manager into `ui.m` for injection at webview creation, and add to Makefile.

**Files:**
- Modify: `Makefile` (add userscript.c to SRC_C, userscript.h to deps)
- Modify: `ui.h` (add `ui_set_userscripts` declaration)
- Modify: `ui.m` (remove hardcoded Reddit/YouTube scripts, inject from manager)

**Step 1: Update Makefile**

In `Makefile`, change line 5:

```makefile
SRC_C = browser.c input.c commands.c storage.c config.c userscript.c
```

And add `userscript.h` to the dependency lists on lines 9 and 12:

```makefile
swim: $(SRC) browser.h input.h commands.h ui.h storage.h config.h userscript.h Info.plist
	$(CC) $(CFLAGS) $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist $(SRC) -o swim

test-ui: $(SRC) test_server.m test_server.h browser.h input.h commands.h ui.h storage.h config.h userscript.h Info.plist
	$(CC) $(CFLAGS) -DSWIM_TEST $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist $(SRC) test_server.m -o swim-test
```

**Step 2: Add `ui_set_userscripts` to `ui.h`**

After `#include "input.h"` (line 4), add:

```c
#include "userscript.h"
```

After `void ui_close(SwimUI *ui);` (line 77), add:

```c
// Userscripts — call before creating any tabs
void ui_set_userscripts(SwimUI *ui, UserScriptManager *scripts);
```

**Step 3: Modify `ui.m`**

Add to `struct SwimUI` (after `bool adblock_enabled;`):

```c
    UserScriptManager *userscripts;
```

Add `ui_set_userscripts` implementation (near `ui_close`):

```objc
void ui_set_userscripts(SwimUI *ui, UserScriptManager *scripts) {
    ui->userscripts = scripts;
}
```

In `create_webview`, **remove** the four blocks that inject kOldRedditCSS, kOldRedditJS, and kYouTubeAdBlockJS (the `WKUserScript` creation + `addUserScript` calls for those three, lines ~726-745).

Replace with a loop that injects matching userscripts:

```objc
    // Userscripts — inject scripts matching any URL (actual URL filtering
    // happens inside each script via @match, but we inject all scripts into
    // all pages since WKUserScript doesn't support per-URL filtering.
    // Scripts with @match self-filter via hostname checks.)
    if (ui->userscripts) {
        for (int i = 0; i < ui->userscripts->count; i++) {
            UserScript *us = &ui->userscripts->scripts[i];
            NSString *src = [NSString stringWithUTF8String:us->source];
            if (!src) continue;
            WKUserScriptInjectionTime timing = (us->run_at == SCRIPT_RUN_AT_DOCUMENT_START)
                ? WKUserScriptInjectionTimeAtDocumentStart
                : WKUserScriptInjectionTimeAtDocumentEnd;
            WKUserScript *script = [[WKUserScript alloc]
                initWithSource:src
                injectionTime:timing
                forMainFrameOnly:YES];
            [config.userContentController addUserScript:script];
        }
    }
```

**Note:** WKUserScript doesn't support per-URL injection natively — all scripts are injected into every page. The old Reddit script already self-filters with `if(window.location.hostname!=='old.reddit.com')return;`. The `@match` metadata is useful for `:scripts` display and future optimization, but injection is all-or-nothing per webview.

Also **remove** the static `kOldRedditCSS`, `kOldRedditJS`, and `kYouTubeAdBlockJS` string constants (lines ~597-703) since they're now in the default script files.

**Step 4: Verify it compiles**

Run: `make clean && make`
Expected: Build succeeds with no errors.

**Step 5: Commit**

```bash
git add Makefile ui.h ui.m
git commit -m "Wire userscript manager into webview creation"
```

---

### Task 3: Startup Loading and Commands

Load scripts at startup, create defaults on first run, register `:scripts` and `:scripts reload` commands.

**Files:**
- Modify: `main.m` (add startup loading, commands)

**Step 1: Add userscript manager to app state**

In `main.m`, find the `static struct { ... } app` block. Add:

```c
    UserScriptManager userscripts;
    char scripts_path[512];
```

**Step 2: Add startup loading**

After `storage_ensure_dir()` (around line 929), add:

```c
        // Userscripts
        snprintf(app.scripts_path, sizeof(app.scripts_path),
            "%s/.config/swim/scripts", home ? home : ".");
        userscript_create_defaults(app.scripts_path);
        userscript_init(&app.userscripts);
        userscript_load_dir(&app.userscripts, app.scripts_path);
```

After `ui_set_adblock(app.ui, ...)` (wherever adblock is initialized), add:

```c
        ui_set_userscripts(app.ui, &app.userscripts);
```

**Step 3: Add `:scripts` command**

Near other `cmd_*` functions:

```objc
static void cmd_scripts(const char *args, void *ctx) {
    (void)ctx;
    if (args && strcmp(args, "reload") == 0) {
        userscript_free(&app.userscripts);
        int n = userscript_load_dir(&app.userscripts, app.scripts_path);
        char msg[128];
        snprintf(msg, sizeof(msg), "Reloaded %d userscript%s", n, n == 1 ? "" : "s");
        ui_set_status_message(app.ui, msg);
        return;
    }

    if (app.userscripts.count == 0) {
        ui_set_status_message(app.ui, "No userscripts loaded");
        return;
    }

    char buf[2048] = {0};
    int pos = 0;
    for (int i = 0; i < app.userscripts.count && pos < (int)sizeof(buf) - 100; i++) {
        UserScript *s = &app.userscripts.scripts[i];
        if (i > 0) pos += snprintf(buf + pos, sizeof(buf) - pos, " | ");
        pos += snprintf(buf + pos, sizeof(buf) - pos, "%s", s->name);
        if (s->match_count > 0) {
            pos += snprintf(buf + pos, sizeof(buf) - pos, " [%s]", s->match[0]);
        }
    }
    ui_set_status_message(app.ui, buf);
}
```

**Step 4: Register command**

In the `registry_add` block:

```c
        registry_add(&app.commands, "scripts", NULL, cmd_scripts, "List/reload userscripts");
```

**Step 5: Add include**

At top of `main.m`, add:

```c
#include "userscript.h"
```

**Step 6: Verify and test**

Run: `make clean && make && make test-ui`

Test via test server:
```bash
./swim-test --test-server 9111 &
sleep 3
# Check scripts are loaded
curl -s -X POST localhost:9111/command -d '{"command":"scripts"}'
# Expected: status message listing old-reddit and youtube-adblock
# Test reload
curl -s -X POST localhost:9111/command -d '{"command":"scripts reload"}'
# Expected: "Reloaded 2 userscripts"
# Navigate to old reddit — verify script works
curl -s -X POST localhost:9111/batch -d '[
  {"type":"command","command":"open https://old.reddit.com/r/popular"},
  {"type":"wait"},
  {"type":"sleep","ms":3000}
]'
curl -s -X POST localhost:9111/eval -H 'Content-Type: application/json' -d '{"js":"JSON.stringify({hasBtn:!!document.getElementById(\"swim-sidebar-btn\"),hasSide:!!document.querySelector(\".side\")})"}'
# Expected: hasBtn:true, hasSide:true
kill %1
```

**Step 7: Commit**

```bash
git add main.m
git commit -m "Add userscript startup loading and :scripts command"
```

---

### Task 4: Clean Up and End-to-End Verification

Remove old hardcoded script constants, update js/ reference copies, full test.

**Files:**
- Modify: `ui.m` (remove dead code)
- Modify: `js/old-reddit.js` (update to match default script)

**Step 1: Remove dead constants from `ui.m`**

Delete the `kOldRedditCSS`, `kOldRedditJS`, and `kYouTubeAdBlockJS` static string constants (if not already removed in Task 2). Also remove the `// (Inline fullscreen...)` comment if present.

**Step 2: Update `js/old-reddit.js`**

Replace with the content from `kDefaultOldReddit` in `userscript.c` (the readable JS version). This is the reference copy.

**Step 3: Create `js/youtube-adblock.js`**

Reference copy matching `kDefaultYouTubeAdblock` in `userscript.c`.

**Step 4: Full rebuild and test**

Run: `make clean && make && make test-ui`

```bash
./swim-test --test-server 9111 &
sleep 3

# Verify default scripts were created
ls -la ~/.config/swim/scripts/

# Test old Reddit
curl -s -X POST localhost:9111/batch -d '[
  {"type":"command","command":"open https://old.reddit.com/r/popular"},
  {"type":"wait"},
  {"type":"sleep","ms":3000}
]'
curl -s -X POST localhost:9111/eval -H 'Content-Type: application/json' -d '{"js":"JSON.stringify({hasBtn:!!document.getElementById(\"swim-sidebar-btn\")})"}'
# Expected: hasBtn:true

# Test YouTube
curl -s -X POST localhost:9111/batch -d '[
  {"type":"command","command":"open https://www.youtube.com"},
  {"type":"wait"},
  {"type":"sleep","ms":3000}
]'
# Verify ad styles injected
curl -s -X POST localhost:9111/eval -H 'Content-Type: application/json' -d '{"js":"!!document.querySelector(\"style\")&&document.querySelectorAll(\"style\").length>0?\"styles present\":\"no styles\""}'

# Test :scripts command
curl -s -X POST localhost:9111/command -d '{"command":"scripts"}'

# Test disable by renaming
mv ~/.config/swim/scripts/youtube-adblock.js ~/.config/swim/scripts/youtube-adblock.js.disabled
curl -s -X POST localhost:9111/command -d '{"command":"scripts reload"}'
# Expected: "Reloaded 1 userscript"

# Re-enable
mv ~/.config/swim/scripts/youtube-adblock.js.disabled ~/.config/swim/scripts/youtube-adblock.js
curl -s -X POST localhost:9111/command -d '{"command":"scripts reload"}'
# Expected: "Reloaded 2 userscripts"

kill %1
```

**Step 5: Commit**

```bash
git add ui.m js/old-reddit.js js/youtube-adblock.js
git commit -m "Remove hardcoded site scripts, update JS reference copies"
```
