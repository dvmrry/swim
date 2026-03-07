#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include "ui.h"

#define MAX_TABS 128

static NSString *const kUserAgent =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

static NSString *const kFocusJS =
    @"document.addEventListener('focusin', function(e) {"
    "var t = e.target.tagName;"
    "if (t === 'INPUT' || t === 'TEXTAREA' || e.target.isContentEditable) {"
    "  window.webkit.messageHandlers.swim.postMessage({type:'focus',focused:true});"
    "}"
    "});"
    "document.addEventListener('focusout', function(e) {"
    "  window.webkit.messageHandlers.swim.postMessage({type:'focus',focused:false});"
    "});";

// --- Status Bar Colors ---

static NSColor *color_for_mode(Mode mode) {
    switch (mode) {
    case MODE_NORMAL:      return [NSColor colorWithSRGBRed:0.6 green:0.8 blue:0.6 alpha:1];
    case MODE_INSERT:      return [NSColor colorWithSRGBRed:0.6 green:0.6 blue:0.9 alpha:1];
    case MODE_COMMAND:     return [NSColor colorWithSRGBRed:0.9 green:0.9 blue:0.6 alpha:1];
    case MODE_HINT:        return [NSColor colorWithSRGBRed:0.9 green:0.6 blue:0.3 alpha:1];
    case MODE_PASSTHROUGH: return [NSColor colorWithSRGBRed:0.7 green:0.5 blue:0.8 alpha:1];
    }
    return [NSColor whiteColor];
}

static const char *mode_name(Mode mode) {
    switch (mode) {
    case MODE_NORMAL:      return "NORMAL";
    case MODE_INSERT:      return "INSERT";
    case MODE_COMMAND:     return "COMMAND";
    case MODE_HINT:        return "HINT";
    case MODE_PASSTHROUGH: return "PASSTHROUGH";
    }
    return "???";
}

// --- Tab Button (for tab bar) ---

@interface SwimTabButton : NSButton
@property (assign) int tabIndex;
@property (assign) int tabId;
@end

@implementation SwimTabButton
@end

// --- Delegates ---

@interface SwimCommandBarDelegate : NSObject <NSTextFieldDelegate>
@property (assign) UICallbacks callbacks;
@end

@implementation SwimCommandBarDelegate
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
    (void)control; (void)textView;
    if (commandSelector == @selector(insertNewline:)) {
        NSTextField *field = (NSTextField *)control;
        const char *text = [field.stringValue UTF8String];
        if (self.callbacks.on_command_submit) {
            self.callbacks.on_command_submit(text, self.callbacks.ctx);
        }
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        if (self.callbacks.on_command_cancel) {
            self.callbacks.on_command_cancel(self.callbacks.ctx);
        }
        return YES;
    }
    return NO;
}
@end

@interface SwimNavDelegate : NSObject <WKNavigationDelegate>
@property (assign) UICallbacks callbacks;
@property (assign) int tabId;
@end

@implementation SwimNavDelegate
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    (void)navigation;
    if (self.callbacks.on_load_changed) {
        self.callbacks.on_load_changed(true, 0.0, self.tabId, self.callbacks.ctx);
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    const char *url = [webView.URL.absoluteString UTF8String];
    const char *title = [webView.title UTF8String];
    if (self.callbacks.on_url_changed && url) {
        self.callbacks.on_url_changed(url, self.tabId, self.callbacks.ctx);
    }
    if (self.callbacks.on_title_changed && title) {
        self.callbacks.on_title_changed(title, self.tabId, self.callbacks.ctx);
    }
    if (self.callbacks.on_load_changed) {
        self.callbacks.on_load_changed(false, 1.0, self.tabId, self.callbacks.ctx);
    }
}
@end

@interface SwimScriptHandler : NSObject <WKScriptMessageHandler>
@property (assign) UICallbacks callbacks;
@end

@implementation SwimScriptHandler
- (void)userContentController:(WKUserContentController *)ctrl
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)ctrl;
    NSDictionary *body = message.body;
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"focus"]) {
        BOOL focused = [body[@"focused"] boolValue];
        if (self.callbacks.on_focus_changed) {
            self.callbacks.on_focus_changed(focused, self.callbacks.ctx);
        }
    } else if ([type isEqualToString:@"hint-activate"]) {
        NSString *url = body[@"url"];
        BOOL newTab = [body[@"newTab"] boolValue];
        if (newTab && url && self.callbacks.on_command_submit) {
            char cmd[4096];
            snprintf(cmd, sizeof(cmd), "tabopen %s", [url UTF8String]);
            self.callbacks.on_command_submit(cmd, self.callbacks.ctx);
        }
    } else if ([type isEqualToString:@"hints-done"] || [type isEqualToString:@"hints-cancelled"]) {
        // Signal focus change to trigger mode-normal
        if (self.callbacks.on_focus_changed) {
            self.callbacks.on_focus_changed(false, self.callbacks.ctx);
        }
    }
}
@end

// --- Tab Entry (UI-side per-tab state) ---

typedef struct UITab {
    WKWebView *webview;
    SwimNavDelegate *navDelegate;
    int tab_id;
} UITab;

// --- SwimUI ---

// --- Find Bar Delegate ---

@class SwimFindBarDelegate;

struct SwimUI {
    NSWindow *window;
    NSView *webviewContainer;  // holds the active webview
    NSScrollView *tabBarScroll;
    NSStackView *tabBar;
    NSTextField *modeLabel;
    NSTextField *urlLabel;
    NSTextField *commandBar;
    NSTextField *findBar;
    NSStackView *statusBar;
    NSView *rootView;
    SwimCommandBarDelegate *cmdDelegate;
    SwimFindBarDelegate *findDelegate;
    SwimScriptHandler *scriptHandler;
    UICallbacks callbacks;

    UITab tabs[MAX_TABS];
    int tab_count;
    int active_tab;  // index into tabs[]

    char find_query[256];

    WKContentRuleList *blockRuleList;
    bool adblock_enabled;
};

@interface SwimFindBarDelegate : NSObject <NSTextFieldDelegate>
@property (assign) SwimUI *ui;
@end

@implementation SwimFindBarDelegate
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
    (void)textView;
    if (commandSelector == @selector(insertNewline:)) {
        // Start search / find next
        NSTextField *field = (NSTextField *)control;
        const char *text = [field.stringValue UTF8String];
        if (text && text[0]) {
            snprintf(self.ui->find_query, sizeof(self.ui->find_query), "%s", text);
            ui_find_next(self.ui);
        }
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        ui_hide_find_bar(self.ui);
        return YES;
    }
    return NO;
}
@end

// Forward declarations
static void tab_bar_clicked(SwimUI *ui, int index);

@interface SwimTabBarHandler : NSObject
@property (assign) SwimUI *ui;
- (void)tabButtonClicked:(SwimTabButton *)sender;
@end

static SwimTabBarHandler *sTabBarHandler;

static NSTextField *make_label(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    label.textColor = [NSColor whiteColor];
    label.drawsBackground = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

// --- Tab Bar Rendering ---

static void rebuild_tab_bar(SwimUI *ui) {
    // Remove all existing buttons
    for (NSView *v in [ui->tabBar.arrangedSubviews copy]) {
        [ui->tabBar removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    for (int i = 0; i < ui->tab_count; i++) {
        UITab *t = &ui->tabs[i];
        NSString *title;
        if (t->webview.title.length > 0) {
            title = t->webview.title;
            if (title.length > 25) {
                title = [[title substringToIndex:22] stringByAppendingString:@"..."];
            }
        } else {
            title = @"New Tab";
        }

        // Add index indicator
        NSString *label = [NSString stringWithFormat:@"%@ %@",
            (i == ui->active_tab ? @"▸" : @" "), title];

        SwimTabButton *btn = [[SwimTabButton alloc] init];
        btn.title = label;
        btn.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        btn.bordered = NO;
        btn.tabIndex = i;
        btn.tabId = t->tab_id;
        btn.target = sTabBarHandler;
        btn.action = @selector(tabButtonClicked:);

        if (i == ui->active_tab) {
            btn.contentTintColor = [NSColor whiteColor];
        } else {
            btn.contentTintColor = [NSColor grayColor];
        }

        [btn setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        [ui->tabBar addArrangedSubview:btn];
    }
}

// --- Tab Bar Click Handler ---

@implementation SwimTabBarHandler
- (void)tabButtonClicked:(SwimTabButton *)sender {
    tab_bar_clicked(self.ui, sender.tabIndex);
}
@end

// --- Hints JS (loaded once) ---

static NSString *sHintsJS = nil;

static NSString *load_hints_js(void) {
    if (sHintsJS) return sHintsJS;
    // Try relative to executable first
    NSString *execPath = [[NSBundle mainBundle] executablePath];
    NSString *execDir = [execPath stringByDeletingLastPathComponent];
    NSString *path = [execDir stringByAppendingPathComponent:@"js/hints.js"];
    sHintsJS = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!sHintsJS) {
        // Try current working directory
        path = @"js/hints.js";
        sHintsJS = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    }
    return sHintsJS;
}

// --- WebView Factory ---

static WKWebView *create_webview(SwimUI *ui, int tab_id) {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.userContentController addScriptMessageHandler:ui->scriptHandler name:@"swim"];

    // Focus detection
    WKUserScript *focusScript = [[WKUserScript alloc]
        initWithSource:kFocusJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:focusScript];

    // Hints JS
    NSString *hintsJS = load_hints_js();
    if (hintsJS) {
        WKUserScript *hintsScript = [[WKUserScript alloc]
            initWithSource:hintsJS
            injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
            forMainFrameOnly:YES];
        [config.userContentController addUserScript:hintsScript];
    }

    // Apply content blocking if enabled
    if (ui->adblock_enabled && ui->blockRuleList) {
        [config.userContentController addContentRuleList:ui->blockRuleList];
    }

    WKWebView *wv = [[WKWebView alloc] initWithFrame:ui->webviewContainer.bounds configuration:config];
    wv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    wv.customUserAgent = kUserAgent;

    SwimNavDelegate *nav = [[SwimNavDelegate alloc] init];
    nav.callbacks = ui->callbacks;
    nav.tabId = tab_id;
    wv.navigationDelegate = nav;

    // Store nav delegate in tab entry (done by caller)
    return wv;
}

// --- Swap Active WebView ---

static void show_webview(SwimUI *ui, int index) {
    // Remove current webview from container
    for (NSView *v in [ui->webviewContainer.subviews copy]) {
        [v removeFromSuperview];
    }

    if (index >= 0 && index < ui->tab_count) {
        WKWebView *wv = ui->tabs[index].webview;
        wv.frame = ui->webviewContainer.bounds;
        [ui->webviewContainer addSubview:wv];
    }
}

static void tab_bar_clicked(SwimUI *ui, int index) {
    if (ui->callbacks.on_tab_selected) {
        ui->callbacks.on_tab_selected(index, ui->callbacks.ctx);
    }
}

// --- Public API ---

SwimUI *ui_create(UICallbacks callbacks) {
    SwimUI *ui = calloc(1, sizeof(SwimUI));
    ui->callbacks = callbacks;
    ui->active_tab = -1;

    // Window
    NSRect frame = NSMakeRect(200, 200, 1024, 768);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    ui->window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:style
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    ui->window.title = @"swim";
    ui->window.backgroundColor = [NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.14 alpha:1];

    // Script handler (shared across all tabs)
    ui->scriptHandler = [[SwimScriptHandler alloc] init];
    ui->scriptHandler.callbacks = callbacks;

    // Tab bar handler
    sTabBarHandler = [[SwimTabBarHandler alloc] init];
    sTabBarHandler.ui = ui;

    // Tab bar
    ui->tabBar = [[NSStackView alloc] init];
    ui->tabBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->tabBar.spacing = 0;
    ui->tabBar.translatesAutoresizingMaskIntoConstraints = NO;

    ui->tabBarScroll = [[NSScrollView alloc] init];
    ui->tabBarScroll.documentView = ui->tabBar;
    ui->tabBarScroll.hasHorizontalScroller = NO;
    ui->tabBarScroll.hasVerticalScroller = NO;
    ui->tabBarScroll.translatesAutoresizingMaskIntoConstraints = NO;
    ui->tabBarScroll.drawsBackground = NO;
    [NSLayoutConstraint activateConstraints:@[
        [ui->tabBarScroll.heightAnchor constraintEqualToConstant:24],
    ]];

    // WebView container (plain NSView, webviews get added/removed as children)
    ui->webviewContainer = [[NSView alloc] init];
    ui->webviewContainer.translatesAutoresizingMaskIntoConstraints = NO;

    // Status bar
    ui->modeLabel = make_label(@"NORMAL");
    ui->modeLabel.backgroundColor = color_for_mode(MODE_NORMAL);
    ui->modeLabel.drawsBackground = YES;
    [ui->modeLabel setContentHuggingPriority:NSLayoutPriorityRequired
                              forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->urlLabel = make_label(@"");
    ui->urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [ui->urlLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->statusBar = [NSStackView stackViewWithViews:@[ui->modeLabel, ui->urlLabel]];
    ui->statusBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->statusBar.spacing = 8;
    ui->statusBar.edgeInsets = NSEdgeInsetsMake(2, 6, 2, 6);
    ui->statusBar.translatesAutoresizingMaskIntoConstraints = NO;

    // Command bar (hidden by default)
    ui->commandBar = [[NSTextField alloc] init];
    ui->commandBar.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    ui->commandBar.placeholderString = @":";
    ui->commandBar.bordered = YES;
    ui->commandBar.hidden = YES;
    ui->commandBar.translatesAutoresizingMaskIntoConstraints = NO;

    ui->cmdDelegate = [[SwimCommandBarDelegate alloc] init];
    ui->cmdDelegate.callbacks = callbacks;
    ui->commandBar.delegate = ui->cmdDelegate;

    // Find bar (hidden by default)
    ui->findBar = [[NSTextField alloc] init];
    ui->findBar.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    ui->findBar.placeholderString = @"/";
    ui->findBar.bordered = YES;
    ui->findBar.hidden = YES;
    ui->findBar.translatesAutoresizingMaskIntoConstraints = NO;

    ui->findDelegate = [[SwimFindBarDelegate alloc] init];
    ui->findDelegate.ui = ui;
    ui->findBar.delegate = ui->findDelegate;

    // Root layout: tab bar, webview container, status bar, find bar, command bar
    ui->rootView = [[NSView alloc] init];
    ui->rootView.translatesAutoresizingMaskIntoConstraints = NO;

    [ui->rootView addSubview:ui->tabBarScroll];
    [ui->rootView addSubview:ui->webviewContainer];
    [ui->rootView addSubview:ui->statusBar];
    [ui->rootView addSubview:ui->findBar];
    [ui->rootView addSubview:ui->commandBar];

    ui->window.contentView = ui->rootView;

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Tab bar at top
        [ui->tabBarScroll.topAnchor constraintEqualToAnchor:ui->rootView.topAnchor],
        [ui->tabBarScroll.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->tabBarScroll.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // WebView container fills middle
        [ui->webviewContainer.topAnchor constraintEqualToAnchor:ui->tabBarScroll.bottomAnchor],
        [ui->webviewContainer.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->webviewContainer.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Status bar below webview
        [ui->statusBar.topAnchor constraintEqualToAnchor:ui->webviewContainer.bottomAnchor],
        [ui->statusBar.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->statusBar.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Find bar below status bar
        [ui->findBar.topAnchor constraintEqualToAnchor:ui->statusBar.bottomAnchor],
        [ui->findBar.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->findBar.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Command bar at bottom
        [ui->commandBar.topAnchor constraintEqualToAnchor:ui->findBar.bottomAnchor],
        [ui->commandBar.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->commandBar.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],
        [ui->commandBar.bottomAnchor constraintEqualToAnchor:ui->rootView.bottomAnchor],
    ]];

    [ui->webviewContainer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationVertical];
    [ui->webviewContainer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                  forOrientation:NSLayoutConstraintOrientationVertical];

    [ui->window makeKeyAndOrderFront:nil];

    return ui;
}

int ui_add_tab(SwimUI *ui, const char *url, int tab_id) {
    if (ui->tab_count >= MAX_TABS) return -1;

    WKWebView *wv = create_webview(ui, tab_id);

    UITab *t = &ui->tabs[ui->tab_count];
    t->webview = wv;
    // Store nav delegate reference from the webview
    t->navDelegate = (SwimNavDelegate *)wv.navigationDelegate;
    t->tab_id = tab_id;

    ui->tab_count++;

    // Select the new tab
    ui->active_tab = ui->tab_count - 1;
    show_webview(ui, ui->active_tab);
    rebuild_tab_bar(ui);

    // Navigate if URL provided
    if (url && url[0]) {
        NSString *urlStr = [NSString stringWithUTF8String:url];
        if (![urlStr hasPrefix:@"http://"] && ![urlStr hasPrefix:@"https://"] && ![urlStr hasPrefix:@"about:"]) {
            urlStr = [@"https://" stringByAppendingString:urlStr];
        }
        NSURL *nsurl = [NSURL URLWithString:urlStr];
        if (nsurl) {
            [wv loadRequest:[NSURLRequest requestWithURL:nsurl]];
        }
    }

    return tab_id;
}

void ui_close_tab(SwimUI *ui, int index) {
    if (index < 0 || index >= ui->tab_count) return;

    // Remove webview
    WKWebView *wv = ui->tabs[index].webview;
    [wv removeFromSuperview];

    // Shift tabs
    for (int i = index; i < ui->tab_count - 1; i++) {
        ui->tabs[i] = ui->tabs[i + 1];
    }
    ui->tab_count--;

    if (ui->tab_count == 0) {
        ui->active_tab = -1;
        show_webview(ui, -1);
    } else {
        if (ui->active_tab >= ui->tab_count) {
            ui->active_tab = ui->tab_count - 1;
        }
        show_webview(ui, ui->active_tab);
    }

    rebuild_tab_bar(ui);
}

void ui_select_tab(SwimUI *ui, int index) {
    if (index < 0 || index >= ui->tab_count) return;
    ui->active_tab = index;
    show_webview(ui, index);
    rebuild_tab_bar(ui);

    // Update URL display
    WKWebView *wv = ui->tabs[index].webview;
    if (wv.URL) {
        const char *url = [wv.URL.absoluteString UTF8String];
        if (url) ui_set_url(ui, url);
    }
}

int ui_tab_count(SwimUI *ui) {
    return ui->tab_count;
}

void ui_update_tab_title(SwimUI *ui, int tab_id, const char *title) {
    (void)title;
    // Find the tab and rebuild the bar to show new title
    for (int i = 0; i < ui->tab_count; i++) {
        if (ui->tabs[i].tab_id == tab_id) {
            rebuild_tab_bar(ui);
            return;
        }
    }
}

void ui_navigate(SwimUI *ui, const char *url) {
    if (ui->active_tab < 0) return;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;

    NSString *urlStr = [NSString stringWithUTF8String:url];
    if (![urlStr hasPrefix:@"http://"] && ![urlStr hasPrefix:@"https://"] && ![urlStr hasPrefix:@"about:"]) {
        urlStr = [@"https://" stringByAppendingString:urlStr];
    }
    NSURL *nsurl = [NSURL URLWithString:urlStr];
    if (nsurl) {
        [wv loadRequest:[NSURLRequest requestWithURL:nsurl]];
    }
}

void ui_run_js(SwimUI *ui, const char *js) {
    if (ui->active_tab < 0) return;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    NSString *jsStr = [NSString stringWithUTF8String:js];
    [wv evaluateJavaScript:jsStr completionHandler:nil];
}

void ui_reload(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    [ui->tabs[ui->active_tab].webview reload];
}

void ui_go_back(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    [ui->tabs[ui->active_tab].webview goBack];
}

void ui_go_forward(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    [ui->tabs[ui->active_tab].webview goForward];
}

void ui_set_mode(SwimUI *ui, Mode mode) {
    ui->modeLabel.stringValue = [NSString stringWithUTF8String:mode_name(mode)];
    ui->modeLabel.backgroundColor = color_for_mode(mode);
}

void ui_set_url(SwimUI *ui, const char *url) {
    ui->urlLabel.stringValue = [NSString stringWithUTF8String:url];
}

void ui_set_progress(SwimUI *ui, double progress) {
    (void)ui; (void)progress;
    // TODO: progress indicator
}

void ui_show_command_bar(SwimUI *ui, const char *prefill) {
    ui->commandBar.hidden = NO;
    ui->commandBar.stringValue = prefill ? [NSString stringWithUTF8String:prefill] : @"";
    [ui->window makeFirstResponder:ui->commandBar];
}

void ui_hide_command_bar(SwimUI *ui) {
    ui->commandBar.hidden = YES;
    ui->commandBar.stringValue = @"";
    if (ui->active_tab >= 0) {
        [ui->window makeFirstResponder:ui->tabs[ui->active_tab].webview];
    }
}

// --- Hint Mode ---

void ui_show_hints(SwimUI *ui, bool new_tab) {
    if (ui->active_tab < 0) return;
    NSString *js = [NSString stringWithFormat:@"window.__swim_hints.show(%@)",
        new_tab ? @"true" : @"false"];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

void ui_filter_hints(SwimUI *ui, const char *typed) {
    if (ui->active_tab < 0 || !typed) return;
    NSString *js = [NSString stringWithFormat:@"window.__swim_hints.filter('%s')", typed];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

void ui_cancel_hints(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:@"window.__swim_hints.remove()"
                                      completionHandler:nil];
}

// --- Find in Page ---

void ui_show_find_bar(SwimUI *ui) {
    ui->findBar.hidden = NO;
    ui->findBar.stringValue = @"";
    [ui->window makeFirstResponder:ui->findBar];
}

void ui_hide_find_bar(SwimUI *ui) {
    ui->findBar.hidden = YES;
    ui->findBar.stringValue = @"";
    ui->find_query[0] = '\0';
    if (ui->active_tab >= 0) {
        // Clear highlights
        NSString *clearJS = @"window.getSelection().removeAllRanges()";
        [ui->tabs[ui->active_tab].webview evaluateJavaScript:clearJS completionHandler:nil];
        [ui->window makeFirstResponder:ui->tabs[ui->active_tab].webview];
    }
}

void ui_find_next(SwimUI *ui) {
    if (ui->active_tab < 0 || !ui->find_query[0]) return;
    NSString *query = [NSString stringWithUTF8String:ui->find_query];
    NSString *js = [NSString stringWithFormat:
        @"window.find('%@', false, false, true)", query];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

void ui_find_prev(SwimUI *ui) {
    if (ui->active_tab < 0 || !ui->find_query[0]) return;
    NSString *query = [NSString stringWithUTF8String:ui->find_query];
    NSString *js = [NSString stringWithFormat:
        @"window.find('%@', false, true, true)", query];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

// --- Content Blocking ---

void ui_load_blocklist(SwimUI *ui) {
    // Try paths relative to executable and cwd
    NSString *execDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];

    NSArray *candidates = @[
        [execDir stringByAppendingPathComponent:@"blocklists/default.json"],
        @"blocklists/default.json",
    ];

    NSString *json = nil;
    for (NSString *p in candidates) {
        json = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (json) break;
    }

    if (!json) return;

    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"swim-adblock"
        encodedContentRuleList:json
        completionHandler:^(WKContentRuleList *list, NSError *error) {
            if (error) {
                NSLog(@"swim: blocklist compile error: %@", error);
                return;
            }
            ui->blockRuleList = list;
            ui->adblock_enabled = true;

            // Apply to all existing tabs
            for (int i = 0; i < ui->tab_count; i++) {
                [ui->tabs[i].webview.configuration.userContentController addContentRuleList:list];
            }
        }];
}

void ui_set_adblock(SwimUI *ui, bool enabled) {
    if (!ui->blockRuleList) return;
    ui->adblock_enabled = enabled;

    for (int i = 0; i < ui->tab_count; i++) {
        WKUserContentController *ucc = ui->tabs[i].webview.configuration.userContentController;
        if (enabled) {
            [ucc addContentRuleList:ui->blockRuleList];
        } else {
            [ucc removeContentRuleList:ui->blockRuleList];
        }
    }
}

void ui_set_window_title(SwimUI *ui, const char *title) {
    if (title && title[0]) {
        ui->window.title = [NSString stringWithFormat:@"%s — swim",
            title];
    } else {
        ui->window.title = @"swim";
    }
}

void ui_close(SwimUI *ui) {
    [ui->window close];
    [NSApp terminate:nil];
}
