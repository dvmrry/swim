# Theme System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Load browser chrome colors from `~/.config/swim/themes/` files, shipping Tokyo Night and Kanagawa as defaults.

**Architecture:** New `theme.c/h` parses key-value theme files with `#hex` colors into an `SwimTheme` struct with 10 color slots. `ui.m` reads theme colors instead of hardcoded values. Default theme files are created on first run. A dark mode userscript ships disabled in `~/.config/swim/scripts/`.

**Tech Stack:** C (parser/loader), Objective-C (NSColor application), hex color parsing

---

### Task 1: Theme Parser and Loader

Create `theme.h` and `theme.c` — the theme struct, hex parser, file loader, and default theme content.

**Files:**
- Create: `theme.h`
- Create: `theme.c`

**Step 1: Create `theme.h`**

```c
#ifndef SWIM_THEME_H
#define SWIM_THEME_H

#include <stdbool.h>

typedef struct {
    float r, g, b;
} ThemeColor;

typedef struct {
    char name[64];
    ThemeColor bg;          // window, tab bar
    ThemeColor status_bg;   // status bar, command bar
    ThemeColor fg;          // active tab text, URL
    ThemeColor fg_dim;      // inactive tab text
    ThemeColor normal;      // normal mode badge
    ThemeColor insert;      // insert mode badge
    ThemeColor command;     // command mode badge, colon prefix
    ThemeColor hint;        // hint mode badge
    ThemeColor passthrough; // passthrough mode badge
    ThemeColor accent;      // progress text, active tab border
} SwimTheme;

// Initialize with hardcoded defaults (current swim colors)
void theme_init_defaults(SwimTheme *t);

// Load theme from file, overriding defaults for any keys present.
// Returns true if file was loaded successfully.
bool theme_load(SwimTheme *t, const char *filepath);

// Create default themes directory with bundled themes.
// Only creates if directory doesn't exist.
void theme_create_defaults(const char *dir_path);

#endif
```

**Step 2: Create `theme.c`**

```c
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
    // Current hardcoded swim colors
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
        // Skip comments and blank lines
        char *p = line;
        while (*p && isspace((unsigned char)*p)) p++;
        if (!*p || *p == '#') continue;

        // Parse key = value
        char *eq = strchr(p, '=');
        if (!eq) continue;

        *eq = '\0';
        char *key = p;
        char *val = eq + 1;

        // Trim key
        char *kend = eq - 1;
        while (kend > key && isspace((unsigned char)*kend)) *kend-- = '\0';

        // Trim value
        while (*val && isspace((unsigned char)*val)) val++;
        char *vend = val + strlen(val) - 1;
        while (vend > val && isspace((unsigned char)*vend)) *vend-- = '\0';

        // Set name from special key
        if (strcmp(key, "name") == 0) {
            snprintf(t->name, sizeof(t->name), "%s", val);
        } else {
            apply_kv(t, key, val);
        }
    }

    fclose(f);
    return true;
}

// --- Default theme content ---

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
    if (stat(dir_path, &st) == 0) return; /* already exists */

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
    mkdir(tmp, 0755);

    char path[1024];

    snprintf(path, sizeof(path), "%s/tokyonight.theme", dir_path);
    FILE *f = fopen(path, "w");
    if (f) { fputs(kTokyoNight, f); fclose(f); }

    snprintf(path, sizeof(path), "%s/kanagawa.theme", dir_path);
    f = fopen(path, "w");
    if (f) { fputs(kKanagawa, f); fclose(f); }
}
```

**Step 3: Verify it compiles**

Run: `cc -fsyntax-only -Wall -Wextra theme.c`
Expected: Clean compile (or warnings only from unused static functions).

**Step 4: Commit**

```bash
git add theme.h theme.c
git commit -m "Add theme parser and loader with Tokyo Night and Kanagawa defaults"
```

---

### Task 2: Integrate into Build and UI

Wire theme colors into `ui.m`, replacing all hardcoded color values. Add to Makefile.

**Files:**
- Modify: `Makefile` (add theme.c to SRC_C, theme.h to deps)
- Modify: `ui.h` (add `ui_set_theme` declaration, include theme.h)
- Modify: `ui.m` (store theme pointer, replace hardcoded colors)

**Step 1: Update Makefile**

In `Makefile`, add `theme.c` to `SRC_C` (line 5):

```makefile
SRC_C = browser.c input.c commands.c storage.c config.c userscript.c theme.c
```

Add `theme.h` to both dependency lines (lines 9 and 12):

```makefile
swim: $(SRC) browser.h input.h commands.h ui.h storage.h config.h userscript.h theme.h Info.plist
```

```makefile
test-ui: $(SRC) test_server.m test_server.h browser.h input.h commands.h ui.h storage.h config.h userscript.h theme.h Info.plist
```

**Step 2: Add `ui_set_theme` to `ui.h`**

After `#include "userscript.h"` (line 5), add:

```c
#include "theme.h"
```

After `void ui_set_userscripts(SwimUI *ui, UserScriptManager *scripts);` (line 81), add:

```c
void ui_set_theme(SwimUI *ui, SwimTheme *theme);
```

**Step 3: Modify `ui.m` — add theme to struct and helper**

Add to `struct SwimUI` (after `UserScriptManager *userscripts;`, line 162):

```c
    SwimTheme *theme;
```

Add a helper function after the `mode_name` function (after line 44). This converts `ThemeColor` to `NSColor*`:

```objc
static NSColor *tc(ThemeColor c) {
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1];
}
```

Add `ui_set_theme` implementation near `ui_set_userscripts`:

```objc
void ui_set_theme(SwimUI *ui, SwimTheme *theme) {
    ui->theme = theme;
}
```

**Step 4: Replace `color_for_mode` function**

Replace the current `color_for_mode` function (lines 24-33) with:

```objc
static NSColor *color_for_mode_themed(SwimUI *ui, Mode mode) {
    if (!ui->theme) {
        // Fallback if no theme set
        switch (mode) {
        case MODE_NORMAL:      return [NSColor colorWithSRGBRed:0.45 green:0.70 blue:0.45 alpha:1];
        case MODE_INSERT:      return [NSColor colorWithSRGBRed:0.45 green:0.55 blue:0.85 alpha:1];
        case MODE_COMMAND:     return [NSColor colorWithSRGBRed:0.82 green:0.75 blue:0.40 alpha:1];
        case MODE_HINT:        return [NSColor colorWithSRGBRed:0.90 green:0.55 blue:0.25 alpha:1];
        case MODE_PASSTHROUGH: return [NSColor colorWithSRGBRed:0.65 green:0.45 blue:0.78 alpha:1];
        }
        return [NSColor whiteColor];
    }
    switch (mode) {
    case MODE_NORMAL:      return tc(ui->theme->normal);
    case MODE_INSERT:      return tc(ui->theme->insert);
    case MODE_COMMAND:     return tc(ui->theme->command);
    case MODE_HINT:        return tc(ui->theme->hint);
    case MODE_PASSTHROUGH: return tc(ui->theme->passthrough);
    }
    return [NSColor whiteColor];
}
```

Note: The old `color_for_mode` was a free function (no `ui` parameter). The new one needs `ui` to access the theme. All call sites must be updated to pass `ui`.

**Step 5: Replace hardcoded colors in `ui_create`**

These are the color assignments that need to change. Each one maps to a theme slot:

In `rebuild_tab_bar` (the function that builds tab buttons, around lines 500-530):
- Line 515: `btn.contentTintColor = [NSColor colorWithSRGBRed:0.90 ...]` → `tc(ui->theme->fg)` (active tab text)
- Line 516: `btn.layer.backgroundColor = [NSColor colorWithSRGBRed:0.22 ...]` → `tc(ui->theme->bg)` with slight offset — or just keep as-is since it's the tab button bg, close to `bg`. Actually: use `[tc(ui->theme->fg_dim) colorWithAlphaComponent:0.15].CGColor` for a subtle highlight. Simpler: just use `[NSColor clearColor].CGColor` and let `bg` show through. The active tab is distinguished by the border, not the button bg. Replace with `[NSColor clearColor].CGColor`.
- Line 520: `border.backgroundColor = color_for_mode(MODE_NORMAL).CGColor` → `color_for_mode_themed(ui, MODE_NORMAL).CGColor`
- Line 524: `btn.contentTintColor = [NSColor colorWithSRGBRed:0.45 ...]` → `tc(ui->theme->fg_dim)` (inactive tab text)

In `ui_create` (the main setup function, around lines 700-850):
- Line 703: window bg `0.12, 0.12, 0.14` → `tc(ui->theme->bg)`
- Line 738: tab bar scroll bg `0.12, 0.12, 0.14` → `tc(ui->theme->bg)`
- Line 750: mode label text `0.08, 0.08, 0.10` → `tc(ui->theme->bg)` (dark text on mode badge)
- Line 751: mode label bg `color_for_mode(MODE_NORMAL)` → `color_for_mode_themed(ui, MODE_NORMAL)`
- Line 760: URL label text `0.67, 0.67, 0.67` → `tc(ui->theme->fg)`
- Line 767: progress label text `0.5, 0.7, 0.9` → `tc(ui->theme->accent)`
- Line 773: pending label text `0.08, 0.08, 0.10` → `tc(ui->theme->bg)` (dark text on badge)
- Line 774: pending label bg `0.80, 0.75, 0.45` → `tc(ui->theme->command)`
- Line 788: status bar bg `0.13, 0.13, 0.15` → `tc(ui->theme->status_bg)`
- Line 805: colon label text `0.82, 0.75, 0.40` → `tc(ui->theme->command)`
- Line 812: command bar bg `0.10, 0.10, 0.12` → `tc(ui->theme->status_bg)`
- Line 828: slash label text `0.7, 0.7, 0.7` → `tc(ui->theme->fg_dim)`
- Line 843: tab separator bg `0.22, 0.22, 0.25` → `tc(ui->theme->status_bg)`

In `ui_set_mode` (around line 1064):
- `ui->modeLabel.backgroundColor = color_for_mode(mode)` → `color_for_mode_themed(ui, mode)`

In `ui_set_progress` (around line 1254):
- Error color `0.9, 0.4, 0.4` — keep as-is (not themed, it's a semantic error color)
- Normal URL color `0.67, 0.67, 0.67` → `tc(ui->theme->fg)`

**Important:** The `ui_set_theme` must be called BEFORE `ui_create` returns, or the theme pointer won't be available during setup. Since `ui_create` is what builds the UI, the theme must be set on the `ui` struct before the color assignments. The cleanest approach: call `ui_set_theme` early in `ui_create` itself (before the color assignments), or pass the theme to `ui_create`. But the current pattern is to call `ui_set_*` after creation. So instead: have `ui_create` check `ui->theme` and fall back to defaults if NULL, and have `main.m` call `ui_set_theme` before `ui_add_tab`. Then theme only applies after the first tab is created.

Actually, the simplest approach: add `SwimTheme *theme` as a parameter to `ui_create`, store it immediately. This way all the color assignments in `ui_create` can use it.

Change `ui_create` signature in `ui.h`:

```c
SwimUI *ui_create(UICallbacks callbacks, bool compact_titlebar, SwimTheme *theme);
```

And in `ui.m`, at the top of `ui_create`, store it:

```objc
SwimUI *ui_create(UICallbacks callbacks, bool compact_titlebar, SwimTheme *theme) {
    SwimUI *ui = calloc(1, sizeof(SwimUI));
    ui->callbacks = callbacks;
    ui->theme = theme;
    // ... rest of function
```

Then `ui_set_theme` is still available for future live-reload but isn't needed at startup.

**Step 6: Verify it compiles**

Run: `make clean && make`
Expected: Build succeeds.

**Step 7: Commit**

```bash
git add Makefile ui.h ui.m
git commit -m "Wire theme colors into UI, replacing hardcoded values"
```

---

### Task 3: Startup Loading and Config

Load theme at startup based on `config.toml`'s `appearance.theme` value.

**Files:**
- Modify: `main.m` (add theme loading at startup, update ui_create call)

**Step 1: Add theme to app state**

In `main.m`, in the `App` struct (after `char scripts_path[512];`), add:

```c
    SwimTheme theme;
    char themes_path[512];
```

**Step 2: Add `#include`**

At top of `main.m`, after `#include "userscript.h"`, add:

```c
#include "theme.h"
```

**Step 3: Add startup loading**

After the userscripts loading block (after `userscript_load_dir(...)` call), add:

```c
        // Theme
        snprintf(app.themes_path, sizeof(app.themes_path),
            "%s/.config/swim/themes", home ? home : ".");
        theme_create_defaults(app.themes_path);
        theme_init_defaults(&app.theme);
        if (app.config.theme[0] && strcmp(app.config.theme, "default") != 0) {
            char theme_path[1024];
            snprintf(theme_path, sizeof(theme_path), "%s/%s.theme",
                app.themes_path, app.config.theme);
            if (!theme_load(&app.theme, theme_path)) {
                fprintf(stderr, "swim: theme '%s' not found\n", app.config.theme);
            }
        }
```

**Step 4: Update `ui_create` call**

Change the existing `ui_create` call from:

```c
        app.ui = ui_create(callbacks, app.config.compact_titlebar);
```

To:

```c
        app.ui = ui_create(callbacks, app.config.compact_titlebar, &app.theme);
```

Remove the `ui_set_theme` call if you added one — passing theme to `ui_create` handles it.

**Step 5: Verify and test**

Run: `make clean && make`

Test manually:
```bash
# Verify default themes were created
ls ~/.config/swim/themes/
# Expected: tokyonight.theme  kanagawa.theme

# Test with Tokyo Night
echo -e '[appearance]\ntheme = "tokyonight"' >> ~/.config/swim/config.toml
./swim
# Expected: Tokyo Night colors visible in tab bar, status bar, mode badges

# Test with Kanagawa
# Edit config.toml: theme = "kanagawa"
# Restart swim
```

**Step 6: Commit**

```bash
git add main.m
git commit -m "Load theme at startup from config"
```

---

### Task 4: Dark Mode Userscript and Cleanup

Add the dark mode userscript as a disabled default, update reference copies.

**Files:**
- Modify: `userscript.c` (add dark-mode.js.disabled to defaults)
- Create: `js/dark-mode.js` (reference copy)

**Step 1: Add dark mode script content to `userscript.c`**

After the `kDefaultYouTubeAdblock` string constant, add:

```c
static const char *kDefaultDarkMode =
    "// ==UserScript==\n"
    "// @name        Dark Mode\n"
    "// @match       *://*/*\n"
    "// @run-at      document-start\n"
    "// ==/UserScript==\n"
    "\n"
    "(function(){\n"
    "var s=document.createElement('style');\n"
    "s.textContent='\\\n"
    "html{filter:invert(1) hue-rotate(180deg)!important}\\\n"
    "img,video,canvas,svg,picture,[style*=\"background-image\"]{filter:invert(1) hue-rotate(180deg)!important}\\\n"
    "';\n"
    "(document.head||document.documentElement).appendChild(s);\n"
    "})();\n";
```

**Step 2: Write dark-mode.js.disabled in `userscript_create_defaults`**

In the `userscript_create_defaults` function, after the YouTube adblock write block, add:

```c
    /* write dark-mode.js.disabled (opt-in) */
    snprintf(path, sizeof(path), "%s/dark-mode.js.disabled", dir_path);
    f = fopen(path, "w");
    if (f) { fputs(kDefaultDarkMode, f); fclose(f); }
```

**Step 3: Create `js/dark-mode.js` reference copy**

```js
// ==UserScript==
// @name        Dark Mode
// @match       *://*/*
// @run-at      document-start
// ==/UserScript==

(function(){
var s=document.createElement('style');
s.textContent='\
html{filter:invert(1) hue-rotate(180deg)!important}\
img,video,canvas,svg,picture,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}\
';
(document.head||document.documentElement).appendChild(s);
})();
```

**Step 4: Full rebuild and verify**

Run: `make clean && make`

To test the dark mode script (requires fresh scripts directory):
```bash
# If you want to test, temporarily rename scripts dir and let it recreate:
mv ~/.config/swim/scripts ~/.config/swim/scripts.bak
./swim &
sleep 2
ls ~/.config/swim/scripts/
# Expected: old-reddit.js  youtube-adblock.js  dark-mode.js.disabled
# Enable it:
mv ~/.config/swim/scripts/dark-mode.js.disabled ~/.config/swim/scripts/dark-mode.js
# Restart swim — pages should be inverted
# Restore:
mv ~/.config/swim/scripts.bak/* ~/.config/swim/scripts/
rmdir ~/.config/swim/scripts.bak
kill %1
```

**Step 5: Commit**

```bash
git add userscript.c js/dark-mode.js
git commit -m "Add dark mode userscript (disabled by default)"
```
