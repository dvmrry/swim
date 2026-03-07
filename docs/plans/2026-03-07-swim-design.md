# swim — Design Document

Minimalist vi-mode web browser for macOS. C/Objective-C, WKWebView.

Successor in spirit to [baud](https://github.com/dvmrry/baud) (Go/darwinkit), rewritten in C to eliminate GC/ARC bridge issues.

## Architecture

Pure C for logic, Objective-C only for macOS platform glue.

```
main.m              NSApp lifecycle, event monitor, wiring
browser.h/c         Tab state, tab list (pure C)
input.h/c           ModeManager, KeyTrie (pure C)
commands.h/c        Registry, aliases, tab completion (pure C)
ui.h/m              Window, StatusBar, CommandBar (ObjC)
js/focus.js         Focus/blur detection for INSERT mode
js/scroll.js        Scroll commands
```

### Data Flow

```
NSEvent → ModeManager → KeyTrie lookup → action callback → UI/Browser update
CommandBar submit → CommandRegistry dispatch → action callback
JS→ObjC: WKScriptMessageHandler → mode change (focus detection)
```

### Key Principle

The ObjC layer is thin. It creates views, forwards events, and updates display. All state and logic lives in pure C structs and functions. Communication from C→ObjC happens through function pointers (callbacks).

## Components

### browser.h/c — Tab State

```c
typedef struct Tab {
    int id;
    char url[2048];
    char title[256];
    bool loading;
    double progress;
    void *webview;  // opaque WKWebView*
} Tab;

typedef struct Browser {
    Tab *tabs;
    int tab_count;
    int tab_capacity;
    int active_tab;
    // closed tab stack for undo
} Browser;
```

### input.h/c — Mode & Key Handling

```c
typedef enum {
    MODE_NORMAL,
    MODE_INSERT,
    MODE_COMMAND,
    MODE_HINT,
    MODE_PASSTHROUGH,
} Mode;

// KeyTrie: prefix tree for multi-key bindings (gg, yy, etc.)
// ModeManager: current mode, mode transitions, key routing
```

### commands.h/c — Command Registry

```c
typedef void (*CommandFn)(const char *args, void *ctx);

// :open <url>, :tabopen <url>, :quit
// Aliases: :o → :open, :q → :quit
// Tab completion on command names
```

### ui.m — macOS UI

- NSWindow with vertical NSStackView layout
- WKWebView fills the main area
- StatusBar: horizontal stack — mode label (color-coded) + URL label + progress
- CommandBar: NSTextField, hidden until : pressed, submits on Enter, cancels on Escape

## Milestone 1 — Window + Navigation

What ships first:
- NSWindow with WKWebView loads a URL (DuckDuckGo default)
- StatusBar shows mode + current URL
- CommandBar: `:open <url>`, `:quit`
- NORMAL mode: j/k scroll, d close, o opens command bar
- INSERT mode: Escape returns to NORMAL
- Mode color in status bar

## Build

```makefile
clang -fobjc-arc -Wall -Wextra -framework Cocoa -framework WebKit \
    main.m ui.m browser.c input.c commands.c -o swim
```

## Aliases

`web` and `www` as shell aliases for `swim`.

## Future

- Tab bar UI, tab switching (J/K)
- Hint mode (f/F)
- Find in page (/)
- Content blocking (WKContentRuleList)
- Config (~/.config/swim/config.toml)
- Bookmarks, history, session restore
- Cross-platform: Linux (WebKitGTK), Windows (WebView2)
