#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Network/Network.h>
#include <strings.h>
#include <math.h>
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
@property (assign) SwimUI *ui;
@end

@interface SwimNavDelegate : NSObject <WKNavigationDelegate>
@property (assign) UICallbacks callbacks;
@property (assign) int tabId;
@property (assign) SwimUI *ui;
@property (weak) id downloadDelegate;
@end

@interface SwimUIDelegate : NSObject <WKUIDelegate>
@property (assign) SwimUI *ui;
@end

@interface SwimDownloadDelegate : NSObject <WKDownloadDelegate>
@property (assign) SwimUI *ui;
@end

@interface SwimScriptHandler : NSObject <WKScriptMessageHandler>
@property (assign) UICallbacks callbacks;
@property (assign) SwimUI *ui;
@end

// Forward declarations for sidebar (struct defined later)
void ui_sidebar_respond(SwimUI *ui, const char *text, bool is_system);

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
    } else if ([type isEqualToString:@"hint-yank"]) {
        NSString *url = body[@"url"];
        if (url) {
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:url forType:NSPasteboardTypeString];
            if (self.ui) {
                ui_set_status_message(self.ui, "Yanked link URL");
            }
        }
    } else if ([type isEqualToString:@"hints-done"] || [type isEqualToString:@"hints-cancelled"]) {
        if (self.callbacks.on_hints_done) {
            self.callbacks.on_hints_done(self.callbacks.ctx);
        }
    } else if ([type isEqualToString:@"sidebar-prompt"]) {
        NSString *text = body[@"text"];
        if (text && self.callbacks.on_sidebar_prompt) {
            self.callbacks.on_sidebar_prompt([text UTF8String], self.callbacks.ctx);
        } else if (text && self.ui) {
            ui_sidebar_respond(self.ui, "No API key configured. Add ai.api_key to config.", true);
        }
    } else if ([type isEqualToString:@"sidebar-escape"]) {
        if (self.ui) {
            ui_hide_sidebar(self.ui);
            // Delay NORMAL to override page auto-focus events
            UICallbacks cbs = self.callbacks;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                    if (cbs.on_focus_changed) cbs.on_focus_changed(false, cbs.ctx);
                });
        }
    }
}
@end

// --- Tab Entry (UI-side per-tab state) ---

typedef struct UITab {
    WKWebView *webview;
    SwimNavDelegate *navDelegate;
    int tab_id;
    bool private_tab;
    char title[256];  // cached title for tab bar display
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
    SwimUIDelegate *uiDelegate;
    SwimDownloadDelegate *downloadDelegate;
    UICallbacks callbacks;

    UITab tabs[MAX_TABS];
    int tab_count;
    int active_tab;  // index into tabs[]

    char find_query[256];
    char saved_url[2048];
    int status_msg_gen;

    NSTextField *pendingLabel;
    NSTextField *progressLabel;
    NSStackView *commandBarContainer;
    NSStackView *findBarContainer;
    NSTextField *colonLabel;
    char cmd_prefix[64];

    NSLayoutConstraint *cmdBarHeight;
    NSLayoutConstraint *findBarHeight;
    NSLayoutConstraint *tabBarHeight;      // zero-height (for hiding)
    NSLayoutConstraint *tabBarNormalHeight; // 28pt (for showing)
    NSLayoutConstraint *statusBarHeight;
    NSView *tabSeparator;

    int tab_bar_mode;     // 0=always, 1=never, 2=auto
    int status_bar_mode;  // 0=always, 1=never, 2=auto
    int status_bar_gen;   // generation counter for auto-hide timeout

    WKContentRuleList *blockRuleList;
    bool adblock_enabled;

    UserScriptManager *userscripts;
    SwimTheme *theme;
    bool serving;
    NSMutableArray *dialog_queue;  // queued dialog events when serving

    // AI Sidebar
    WKWebView *sidebarWebview;
    NSView *sidebarContainer;
    NSView *sidebarSeparator;
    NSView *contentSplit;  // horizontal container: webview + sidebar
    NSLayoutConstraint *sidebarWidth;
    NSLayoutConstraint *sidebarZeroWidth;
    NSLayoutConstraint *sidebarSepWidth;
    bool sidebar_visible;
};

// --- Theme Colors ---

static NSColor *tc(ThemeColor c) {
    return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1];
}

static void theme_hex_ui(ThemeColor c, char *buf) {
    snprintf(buf, 8, "#%02x%02x%02x",
        (int)(c.r * 255), (int)(c.g * 255), (int)(c.b * 255));
}

// Sidebar HTML template
static const char *kSidebarHTML =
#include "sidebar_html.inc"
;

static NSString *build_sidebar_html(SwimTheme *theme) {
    char bg[8], status_bg[8], fg[8], fg_dim[8], accent[8];
    theme_hex_ui(theme->bg, bg);
    theme_hex_ui(theme->status_bg, status_bg);
    theme_hex_ui(theme->fg, fg);
    theme_hex_ui(theme->fg_dim, fg_dim);
    theme_hex_ui(theme->accent, accent);

    // fg_dim but slightly brighter for AI responses
    char fg_dim_bright[8];
    snprintf(fg_dim_bright, 8, "#%02x%02x%02x",
        (int)(fmin(1.0, theme->fg_dim.r + 0.15) * 255),
        (int)(fmin(1.0, theme->fg_dim.g + 0.15) * 255),
        (int)(fmin(1.0, theme->fg_dim.b + 0.15) * 255));

    NSMutableString *html = [NSMutableString stringWithUTF8String:kSidebarHTML];
    [html replaceOccurrencesOfString:@"%BG%" withString:@(bg)
        options:0 range:NSMakeRange(0, html.length)];
    [html replaceOccurrencesOfString:@"%STATUS_BG%" withString:@(status_bg)
        options:0 range:NSMakeRange(0, html.length)];
    [html replaceOccurrencesOfString:@"%FG%" withString:@(fg)
        options:0 range:NSMakeRange(0, html.length)];
    [html replaceOccurrencesOfString:@"%FG_DIM%" withString:@(fg_dim)
        options:0 range:NSMakeRange(0, html.length)];
    [html replaceOccurrencesOfString:@"%FG_DIM_BRIGHT%" withString:@(fg_dim_bright)
        options:0 range:NSMakeRange(0, html.length)];
    [html replaceOccurrencesOfString:@"%ACCENT%" withString:@(accent)
        options:0 range:NSMakeRange(0, html.length)];
    return html;
}

static NSString *normalize_url(NSString *urlStr) {
    if (![urlStr hasPrefix:@"http://"] && ![urlStr hasPrefix:@"https://"] && ![urlStr hasPrefix:@"about:"]) {
        return [@"https://" stringByAppendingString:urlStr];
    }
    return urlStr;
}

// 0=always, 1=never, 2=auto
static int parse_bar_mode(const char *mode) {
    if (strcmp(mode, "never") == 0) return 1;
    if (strcmp(mode, "auto") == 0) return 2;
    return 0;
}

void ui_sidebar_respond(SwimUI *ui, const char *text, bool is_system) {
    NSString *escaped = [[NSString stringWithUTF8String:text]
        stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    NSString *fn = is_system ? @"receiveSystem" : @"receiveResponse";
    NSString *js = [NSString stringWithFormat:@"%@('%@')", fn, escaped];
    [ui->sidebarWebview evaluateJavaScript:js completionHandler:nil];
}

static bool is_blocked_scheme(const char *url) {
    return strncasecmp(url, "javascript:", 11) == 0 ||
           strncasecmp(url, "data:", 5) == 0 ||
           strncasecmp(url, "file:", 5) == 0;
}

static NSColor *color_for_mode(SwimUI *ui, Mode mode) {
    if (ui->theme) {
        switch (mode) {
        case MODE_NORMAL:      return tc(ui->theme->normal);
        case MODE_INSERT:      return tc(ui->theme->insert);
        case MODE_COMMAND:     return tc(ui->theme->command);
        case MODE_HINT:        return tc(ui->theme->hint);
        case MODE_PASSTHROUGH: return tc(ui->theme->passthrough);
        }
    }
    switch (mode) {
    case MODE_NORMAL:      return [NSColor colorWithSRGBRed:0.45 green:0.70 blue:0.45 alpha:1];
    case MODE_INSERT:      return [NSColor colorWithSRGBRed:0.45 green:0.55 blue:0.85 alpha:1];
    case MODE_COMMAND:     return [NSColor colorWithSRGBRed:0.82 green:0.75 blue:0.40 alpha:1];
    case MODE_HINT:        return [NSColor colorWithSRGBRed:0.90 green:0.55 blue:0.25 alpha:1];
    case MODE_PASSTHROUGH: return [NSColor colorWithSRGBRed:0.65 green:0.45 blue:0.78 alpha:1];
    }
    return [NSColor whiteColor];
}

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

@implementation SwimCommandBarDelegate
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
    (void)control; (void)textView;
    if (commandSelector == @selector(insertNewline:)) {
        NSTextField *field = (NSTextField *)control;
        NSString *text;
        if (self.ui && self.ui->cmd_prefix[0]) {
            text = [NSString stringWithFormat:@"%s%@",
                self.ui->cmd_prefix, field.stringValue];
        } else {
            text = field.stringValue;
        }
        if (self.callbacks.on_command_submit) {
            self.callbacks.on_command_submit([text UTF8String], self.callbacks.ctx);
        }
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        if (self.callbacks.on_command_cancel) {
            self.callbacks.on_command_cancel(self.callbacks.ctx);
        }
        return YES;
    }
    if (commandSelector == @selector(insertTab:)) {
        if (self.callbacks.on_command_complete) {
            NSTextField *field = (NSTextField *)control;
            const char *text = [field.stringValue UTF8String];
            if (text) {
                const char *cmd_pfx = self.ui ? self.ui->cmd_prefix : "";
                const char *completed = self.callbacks.on_command_complete(
                    text, cmd_pfx, self.callbacks.ctx);
                if (completed) {
                    field.stringValue = [NSString stringWithUTF8String:completed];
                    NSText *editor = [self.ui->window fieldEditor:YES forObject:field];
                    [editor setSelectedRange:NSMakeRange(editor.string.length, 0)];
                }
            }
        }
        return YES;
    }
    return NO;
}
@end

// --- SwimNavDelegate ---

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
    if (self.callbacks.on_nav_error) {
        self.callbacks.on_nav_error(NULL, self.tabId, self.callbacks.ctx);
    }
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

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    (void)navigation;
    if (error.code == NSURLErrorCancelled) return;  // normal nav cancel
    if (self.callbacks.on_load_changed) {
        self.callbacks.on_load_changed(false, 1.0, self.tabId, self.callbacks.ctx);
    }
    NSLog(@"swim: nav error: %@", error.localizedDescription);
    if (self.callbacks.on_nav_error) {
        self.callbacks.on_nav_error([error.localizedDescription UTF8String],
                                    self.tabId, self.callbacks.ctx);
    }
    if (self.ui) {
        NSString *msg = [NSString stringWithFormat:@"Error: %@", error.localizedDescription];
        ui_set_status_message(self.ui, [msg UTF8String]);
    }
}

// KVO for estimatedProgress
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    (void)change; (void)context;
    if ([keyPath isEqualToString:@"estimatedProgress"]) {
        WKWebView *wv = (WKWebView *)object;
        if (self.callbacks.on_load_changed) {
            self.callbacks.on_load_changed(wv.isLoading, wv.estimatedProgress,
                self.tabId, self.callbacks.ctx);
        }
    }
}

// Download detection — non-displayable content
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if (!navigationResponse.canShowMIMEType) {
        decisionHandler(WKNavigationResponsePolicyDownload);
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

// Download detection + Cmd-click opens in new tab
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (navigationAction.shouldPerformDownload) {
        decisionHandler(WKNavigationActionPolicyDownload);
        return;
    }
    // Allow iframe navigations without interference
    if (!navigationAction.targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    // Cmd-click or middle-click → open in new tab
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated &&
        (navigationAction.modifierFlags & NSEventModifierFlagCommand)) {
        NSURL *url = navigationAction.request.URL;
        if (url && self.callbacks.on_command_submit) {
            char cmd[4096];
            snprintf(cmd, sizeof(cmd), "tabopen %s", [url.absoluteString UTF8String]);
            self.callbacks.on_command_submit(cmd, self.callbacks.ctx);
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
    navigationAction:(WKNavigationAction *)navigationAction
    didBecomeDownload:(WKDownload *)download {
    (void)webView; (void)navigationAction;
    download.delegate = self.downloadDelegate;
}

- (void)webView:(WKWebView *)webView
    navigationResponse:(WKNavigationResponse *)navigationResponse
    didBecomeDownload:(WKDownload *)download {
    (void)webView; (void)navigationResponse;
    download.delegate = self.downloadDelegate;
}
@end

// --- SwimUIDelegate (target=_blank, JS alerts, file uploads) ---

@implementation SwimUIDelegate
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
       forNavigationAction:(WKNavigationAction *)navigationAction
            windowFeatures:(WKWindowFeatures *)windowFeatures {
    (void)configuration; (void)windowFeatures;
    // Handle target="_blank" and window.open() — open in new tab
    // Inherit private state from the source tab
    NSURL *url = navigationAction.request.URL;
    if (url && self.ui->callbacks.on_command_submit) {
        bool source_private = false;
        for (int i = 0; i < self.ui->tab_count; i++) {
            if (self.ui->tabs[i].webview == webView) {
                source_private = self.ui->tabs[i].private_tab;
                break;
            }
        }
        char cmd[4096];
        snprintf(cmd, sizeof(cmd), "%s %s",
                 source_private ? "private" : "tabopen",
                 [url.absoluteString UTF8String]);
        self.ui->callbacks.on_command_submit(cmd, self.ui->callbacks.ctx);
    }
    return nil;
}

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                     initiatedByFrame:(WKFrameInfo *)frame
                    completionHandler:(void (^)(void))completionHandler {
    if (self.ui->serving) {
        if (!self.ui->dialog_queue) self.ui->dialog_queue = [NSMutableArray new];
        [self.ui->dialog_queue addObject:@{
            @"type": @"alert", @"message": message ?: @"",
            @"origin": frame.request.URL.host ?: @"",
            @"auto_response": @"accepted",
            @"ts": @((long long)([[NSDate date] timeIntervalSince1970] * 1000))
        }];
        if (self.ui->dialog_queue.count > 50) [self.ui->dialog_queue removeObjectAtIndex:0];
        completionHandler();
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = [NSString stringWithFormat:@"From: %@", frame.request.URL.host];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    completionHandler();
}

- (void)webView:(WKWebView *)webView
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                       initiatedByFrame:(WKFrameInfo *)frame
                      completionHandler:(void (^)(BOOL))completionHandler {
    if (self.ui->serving) {
        if (!self.ui->dialog_queue) self.ui->dialog_queue = [NSMutableArray new];
        [self.ui->dialog_queue addObject:@{
            @"type": @"confirm", @"message": message ?: @"",
            @"origin": frame.request.URL.host ?: @"",
            @"auto_response": @"accepted",
            @"ts": @((long long)([[NSDate date] timeIntervalSince1970] * 1000))
        }];
        if (self.ui->dialog_queue.count > 50) [self.ui->dialog_queue removeObjectAtIndex:0];
        completionHandler(YES);
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    alert.informativeText = [NSString stringWithFormat:@"From: %@", frame.request.URL.host];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [alert runModal];
    completionHandler(response == NSAlertFirstButtonReturn);
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                             defaultText:(NSString *)defaultText
                        initiatedByFrame:(WKFrameInfo *)frame
                       completionHandler:(void (^)(NSString *))completionHandler {
    if (self.ui->serving) {
        if (!self.ui->dialog_queue) self.ui->dialog_queue = [NSMutableArray new];
        [self.ui->dialog_queue addObject:@{
            @"type": @"prompt", @"message": prompt ?: @"",
            @"default_text": defaultText ?: @"",
            @"origin": frame.request.URL.host ?: @"",
            @"auto_response": defaultText ?: @"",
            @"ts": @((long long)([[NSDate date] timeIntervalSince1970] * 1000))
        }];
        if (self.ui->dialog_queue.count > 50) [self.ui->dialog_queue removeObjectAtIndex:0];
        completionHandler(defaultText ?: @"");
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = prompt;
    alert.informativeText = [NSString stringWithFormat:@"From: %@", frame.request.URL.host];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    input.stringValue = defaultText ? defaultText : @"";
    alert.accessoryView = input;
    NSModalResponse response = [alert runModal];
    completionHandler(response == NSAlertFirstButtonReturn ? input.stringValue : nil);
}

- (void)webView:(WKWebView *)webView
    runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
              initiatedByFrame:(WKFrameInfo *)frame
             completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler {
    (void)frame;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    if ([panel runModal] == NSModalResponseOK) {
        completionHandler(panel.URLs);
    } else {
        completionHandler(nil);
    }
}

@end

// --- SwimDownloadDelegate ---

@implementation SwimDownloadDelegate
- (void)download:(WKDownload *)download
    decideDestinationUsingResponse:(NSURLResponse *)response
                 suggestedFilename:(NSString *)suggestedFilename
                 completionHandler:(void (^)(NSURL *))completionHandler {
    (void)download; (void)response;
    NSString *downloads = [NSSearchPathForDirectoriesInDomains(
        NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [downloads stringByAppendingPathComponent:suggestedFilename];

    // Avoid overwriting existing files
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = [path stringByDeletingPathExtension];
    NSString *ext = [path pathExtension];
    int i = 1;
    while ([fm fileExistsAtPath:path]) {
        if (ext.length > 0) {
            path = [NSString stringWithFormat:@"%@-%d.%@", base, i++, ext];
        } else {
            path = [NSString stringWithFormat:@"%@-%d", base, i++];
        }
    }

    if (self.ui) {
        char msg[512];
        snprintf(msg, sizeof(msg), "Downloading: %s", [suggestedFilename UTF8String]);
        ui_set_status_message(self.ui, msg);
    }
    completionHandler([NSURL fileURLWithPath:path]);
}

- (void)download:(WKDownload *)download
    didFailWithError:(NSError *)error
          resumeData:(NSData *)resumeData {
    (void)download; (void)resumeData;
    NSLog(@"swim: download failed: %@", error.localizedDescription);
    if (self.ui) {
        NSString *msg = [NSString stringWithFormat:@"Download failed: %@", error.localizedDescription];
        ui_set_status_message(self.ui, [msg UTF8String]);
    }
}

- (void)downloadDidFinish:(WKDownload *)download {
    (void)download;
    if (self.ui) {
        ui_set_status_message(self.ui, "Download complete");
    }
}
@end

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
        } else if (t->title[0]) {
            title = [NSString stringWithUTF8String:t->title];
        } else {
            title = @"New Tab";
        }
        if (title.length > 20) {
            title = [[title substringToIndex:18] stringByAppendingString:@".."];
        }

        NSString *label = t->private_tab
            ? [NSString stringWithFormat:@" %d \xF0\x9F\x94\x92%@ ", i + 1, title]
            : [NSString stringWithFormat:@" %d %@ ", i + 1, title];

        SwimTabButton *btn = [SwimTabButton buttonWithTitle:label
            target:sTabBarHandler action:@selector(tabButtonClicked:)];
        btn.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        btn.bordered = NO;
        btn.bezelStyle = NSBezelStyleAccessoryBarAction;
        btn.tabIndex = i;
        btn.tabId = t->tab_id;
        btn.wantsLayer = YES;
        btn.layer.masksToBounds = YES;

        if (i == ui->active_tab) {
            btn.contentTintColor = tc(ui->theme->fg);
            btn.layer.backgroundColor = [NSColor clearColor].CGColor;
            CALayer *border = [CALayer layer];
            border.frame = CGRectMake(0, 0, 2000, 2);
            border.backgroundColor = color_for_mode(ui, MODE_NORMAL).CGColor;
            border.name = @"tabBorder";
            [btn.layer addSublayer:border];
        } else {
            btn.contentTintColor = tc(ui->theme->fg_dim);
            btn.layer.backgroundColor = [NSColor clearColor].CGColor;
        }

        [btn setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn.heightAnchor constraintEqualToConstant:28].active = YES;
        [ui->tabBar addArrangedSubview:btn];
    }

    // Tab bar visibility based on mode
    bool show;
    if (ui->tab_bar_mode == 1) show = false;       // never
    else if (ui->tab_bar_mode == 2) show = (ui->tab_count > 1); // auto
    else show = true;                                // always
    ui->tabBarScroll.hidden = !show;
    ui->tabSeparator.hidden = !show;
    ui->tabBarNormalHeight.active = show;
    ui->tabBarHeight.active = !show;
}

// --- Tab Bar Click Handler ---

@implementation SwimTabBarHandler
- (void)tabButtonClicked:(SwimTabButton *)sender {
    tab_bar_clicked(self.ui, sender.tabIndex);
}
@end

// --- Hints JS (embedded) ---

static NSString *const kHintsJS =
    @"(function(){"
    "var C='asdfghjkl',hints=[],box=null;"
    "function labels(n){"
    "  var r=[],L=C.length;"
    "  if(n<=L){for(var i=0;i<n;i++)r.push(C[i])}"
    "  else{for(var i=0;i<L&&r.length<n;i++)for(var j=0;j<L&&r.length<n;j++)r.push(C[i]+C[j])}"
    "  return r}"
    "function find(){"
    "  var s='a[href],button,input,select,textarea,[onclick],[role=button],[role=link],[tabindex],summary';"
    "  var els=document.querySelectorAll(s),v=[];"
    "  for(var i=0;i<els.length;i++){"
    "    var r=els[i].getBoundingClientRect();"
    "    if(r.width>0&&r.height>0&&r.top<innerHeight&&r.bottom>0&&r.left<innerWidth&&r.right>0)"
    "      v.push({el:els[i],r:r})}"
    "  return v}"
    "function show(mode){"
    "  rm();var cl=find();if(!cl.length)return;"
    "  var lb=labels(cl.length);"
    "  box=document.createElement('div');box.id='__sh';"
    "  document.body.appendChild(box);"
    "  for(var i=0;i<cl.length;i++){"
    "    var o=document.createElement('div');"
    "    o.textContent=lb[i];"
    "    o.style.cssText='position:fixed;z-index:2147483647;background:#f0e040;color:#000;"
    "font:bold 11px monospace;padding:1px 3px;border:1px solid #c0a020;border-radius:2px;"
    "pointer-events:none;line-height:1.2;';"
    "    o.style.left=cl[i].r.left+'px';o.style.top=cl[i].r.top+'px';"
    "    box.appendChild(o);"
    "    hints.push({el:cl[i].el,label:lb[i],ov:o,mode:mode})}}"
    "function filter(typed){"
    "  var rem=0,last=null;"
    "  for(var i=0;i<hints.length;i++){"
    "    var h=hints[i];"
    "    if(h.label.indexOf(typed)===0){h.ov.style.display='';rem++;last=h;"
    "      h.ov.innerHTML='<span style=\"color:#d00\">'+typed+'</span>'+h.label.slice(typed.length)}"
    "    else{h.ov.style.display='none'}}"
    "  if(rem===1&&last.label===typed){activate(last)}"
    "  else if(rem===0){rm();window.webkit.messageHandlers.swim.postMessage({type:'hints-cancelled'})}}"
    "function activate(h){"
    "  rm();"
    "  var href=h.el.href||(h.el.closest&&h.el.closest('a[href]')&&h.el.closest('a[href]').href);"
    "  if(h.mode===2){"
    "    if(href)window.webkit.messageHandlers.swim.postMessage({type:'hint-yank',url:href})"
    "  }else if(h.mode===1){"
    "    if(href)window.webkit.messageHandlers.swim.postMessage({type:'hint-activate',url:href,newTab:true})"
    "  }else{"
    "    h.el.click();"
    "    if(h.el.tagName==='INPUT'||h.el.tagName==='TEXTAREA'||h.el.tagName==='SELECT')h.el.focus()}"
    "  window.webkit.messageHandlers.swim.postMessage({type:'hints-done'})}"
    "function rm(){if(box){box.remove();box=null}hints=[]}"
    "window.__swim_hints={show:show,filter:filter,remove:function(){rm();"
    "  window.webkit.messageHandlers.swim.postMessage({type:'hints-cancelled'})}};"
    "})();";


// --- WebView Factory ---

static WKWebView *create_webview(SwimUI *ui, int tab_id, bool private_tab, SwimNavDelegate **out_nav) {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.preferences.elementFullscreenEnabled = NO;
    [config.preferences setValue:@NO forKey:@"javaScriptCanAccessClipboard"];
    if (private_tab) {
        config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    }
    [config.userContentController addScriptMessageHandler:ui->scriptHandler name:@"swim"];

    // Focus detection
    WKUserScript *focusScript = [[WKUserScript alloc]
        initWithSource:kFocusJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:focusScript];

    // Hints JS
    WKUserScript *hintsScript = [[WKUserScript alloc]
        initWithSource:kHintsJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:hintsScript];

    // Userscripts — inject all loaded scripts (they self-filter via hostname checks)
    if (ui->userscripts) {
        for (int i = 0; i < ui->userscripts->count; i++) {
            UserScript *us = &ui->userscripts->scripts[i];
            NSString *src = [NSString stringWithUTF8String:us->source];
            if (!src) continue;
            WKUserScriptInjectionTime timing = (us->run_at == SCRIPT_RUN_AT_DOCUMENT_START)
                ? WKUserScriptInjectionTimeAtDocumentStart
                : WKUserScriptInjectionTimeAtDocumentEnd;
            WKUserScript *userScript = [[WKUserScript alloc]
                initWithSource:src
                injectionTime:timing
                forMainFrameOnly:YES];
            [config.userContentController addUserScript:userScript];
        }
    }

    // Apply content blocking if enabled
    if (ui->adblock_enabled && ui->blockRuleList) {
        [config.userContentController addContentRuleList:ui->blockRuleList];
    }

    WKWebView *wv = [[WKWebView alloc] initWithFrame:ui->webviewContainer.bounds configuration:config];
    wv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    wv.customUserAgent = kUserAgent;
    wv.allowsBackForwardNavigationGestures = YES;

    // Inherit dark mode appearance from window
    if (ui->window.appearance) {
        wv.appearance = ui->window.appearance;
    }

    SwimNavDelegate *nav = [[SwimNavDelegate alloc] init];
    nav.callbacks = ui->callbacks;
    nav.tabId = tab_id;
    nav.ui = ui;
    nav.downloadDelegate = ui->downloadDelegate;
    wv.navigationDelegate = nav;
    wv.UIDelegate = ui->uiDelegate;

    // KVO for real-time progress updates
    [wv addObserver:nav forKeyPath:@"estimatedProgress"
            options:NSKeyValueObservingOptionNew context:NULL];

    // Return delegate so caller can hold a strong reference
    // (wv.navigationDelegate is weak — without this, nav gets deallocated)
    *out_nav = nav;
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

// Auto-show status bar then schedule hide after timeout
static void status_bar_flash(SwimUI *ui) {
    if (ui->status_bar_mode != 2) return; // only for auto mode
    ui->statusBar.hidden = NO;
    ui->statusBarHeight.active = NO;
    int gen = ++ui->status_bar_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (ui->status_bar_gen == gen && ui->status_bar_mode == 2) {
                ui->statusBar.hidden = YES;
                ui->statusBarHeight.active = YES;
            }
        });
}

static void tab_bar_clicked(SwimUI *ui, int index) {
    if (ui->callbacks.on_tab_selected) {
        ui->callbacks.on_tab_selected(index, ui->callbacks.ctx);
    }
}

// --- Public API ---

SwimUI *ui_create(UICallbacks callbacks, bool compact_titlebar, const char *tab_bar_mode, const char *status_bar_mode, SwimTheme *theme) {
    SwimUI *ui = calloc(1, sizeof(SwimUI));
    ui->callbacks = callbacks;
    ui->active_tab = -1;
    ui->theme = theme;
    ui->tab_bar_mode = parse_bar_mode(tab_bar_mode);
    ui->status_bar_mode = parse_bar_mode(status_bar_mode);

    // Window
    NSRect frame = NSMakeRect(200, 200, 1024, 768);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    if (compact_titlebar) style |= NSWindowStyleMaskFullSizeContentView;
    ui->window = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:style
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    ui->window.title = @"swim";
    ui->window.backgroundColor = tc(ui->theme->bg);
    if (compact_titlebar) {
        ui->window.titlebarAppearsTransparent = YES;
        ui->window.titleVisibility = NSWindowTitleHidden;
    }

    // Script handler (shared across all tabs)
    ui->scriptHandler = [[SwimScriptHandler alloc] init];
    ui->scriptHandler.callbacks = callbacks;
    ui->scriptHandler.ui = ui;

    // UI delegate (JS alerts, target=_blank, file uploads)
    ui->uiDelegate = [[SwimUIDelegate alloc] init];
    ui->uiDelegate.ui = ui;

    // Download delegate
    ui->downloadDelegate = [[SwimDownloadDelegate alloc] init];
    ui->downloadDelegate.ui = ui;

    // Tab bar handler
    sTabBarHandler = [[SwimTabBarHandler alloc] init];
    sTabBarHandler.ui = ui;

    // Tab bar
    ui->tabBar = [[NSStackView alloc] init];
    ui->tabBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->tabBar.alignment = NSLayoutAttributeCenterY;
    ui->tabBar.spacing = 0;
    ui->tabBar.translatesAutoresizingMaskIntoConstraints = NO;

    ui->tabBarScroll = [[NSScrollView alloc] init];
    ui->tabBarScroll.documentView = ui->tabBar;
    ui->tabBarScroll.hasHorizontalScroller = NO;
    ui->tabBarScroll.hasVerticalScroller = NO;
    ui->tabBarScroll.translatesAutoresizingMaskIntoConstraints = NO;
    ui->tabBarScroll.drawsBackground = YES;
    ui->tabBarScroll.backgroundColor = tc(ui->theme->bg);
    ui->tabBarNormalHeight = [ui->tabBarScroll.heightAnchor constraintEqualToConstant:28];
    ui->tabBarNormalHeight.active = YES;

    // WebView container (plain NSView, webviews get added/removed as children)
    ui->webviewContainer = [[NSView alloc] init];
    ui->webviewContainer.translatesAutoresizingMaskIntoConstraints = NO;

    // AI Sidebar
    WKWebViewConfiguration *sidebarConfig = [[WKWebViewConfiguration alloc] init];
    [sidebarConfig.userContentController addScriptMessageHandler:ui->scriptHandler name:@"swim"];
    ui->sidebarWebview = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:sidebarConfig];
    ui->sidebarWebview.translatesAutoresizingMaskIntoConstraints = NO;

    ui->sidebarSeparator = [[NSView alloc] init];
    ui->sidebarSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    ui->sidebarSeparator.wantsLayer = YES;
    ui->sidebarSeparator.layer.backgroundColor = (tc(ui->theme->status_bg)).CGColor;

    ui->sidebarContainer = [[NSView alloc] init];
    ui->sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [ui->sidebarContainer addSubview:ui->sidebarWebview];
    [NSLayoutConstraint activateConstraints:@[
        [ui->sidebarWebview.topAnchor constraintEqualToAnchor:ui->sidebarContainer.topAnchor],
        [ui->sidebarWebview.bottomAnchor constraintEqualToAnchor:ui->sidebarContainer.bottomAnchor],
        [ui->sidebarWebview.leadingAnchor constraintEqualToAnchor:ui->sidebarContainer.leadingAnchor],
        [ui->sidebarWebview.trailingAnchor constraintEqualToAnchor:ui->sidebarContainer.trailingAnchor],
    ]];

    // Content split: webview container + separator + sidebar
    ui->contentSplit = [[NSView alloc] init];
    ui->contentSplit.translatesAutoresizingMaskIntoConstraints = NO;
    [ui->contentSplit addSubview:ui->webviewContainer];
    [ui->contentSplit addSubview:ui->sidebarSeparator];
    [ui->contentSplit addSubview:ui->sidebarContainer];

    [NSLayoutConstraint activateConstraints:@[
        [ui->webviewContainer.topAnchor constraintEqualToAnchor:ui->contentSplit.topAnchor],
        [ui->webviewContainer.bottomAnchor constraintEqualToAnchor:ui->contentSplit.bottomAnchor],
        [ui->webviewContainer.leadingAnchor constraintEqualToAnchor:ui->contentSplit.leadingAnchor],

        [ui->sidebarSeparator.topAnchor constraintEqualToAnchor:ui->contentSplit.topAnchor],
        [ui->sidebarSeparator.bottomAnchor constraintEqualToAnchor:ui->contentSplit.bottomAnchor],
        [ui->sidebarSeparator.leadingAnchor constraintEqualToAnchor:ui->webviewContainer.trailingAnchor],

        [ui->sidebarContainer.topAnchor constraintEqualToAnchor:ui->contentSplit.topAnchor],
        [ui->sidebarContainer.bottomAnchor constraintEqualToAnchor:ui->contentSplit.bottomAnchor],
        [ui->sidebarContainer.leadingAnchor constraintEqualToAnchor:ui->sidebarSeparator.trailingAnchor],
        [ui->sidebarContainer.trailingAnchor constraintEqualToAnchor:ui->contentSplit.trailingAnchor],
    ]];

    // Sidebar width constraints (toggle between 320 and 0)
    ui->sidebarWidth = [ui->sidebarContainer.widthAnchor constraintEqualToConstant:320];
    ui->sidebarZeroWidth = [ui->sidebarContainer.widthAnchor constraintEqualToConstant:0];
    ui->sidebarSepWidth = [ui->sidebarSeparator.widthAnchor constraintEqualToConstant:1];
    ui->sidebarZeroWidth.active = YES;
    ui->sidebarSepWidth.active = YES;
    ui->sidebarContainer.hidden = YES;
    ui->sidebarSeparator.hidden = YES;
    ui->sidebar_visible = false;

    // Load sidebar HTML
    NSString *sidebarHTML = build_sidebar_html(ui->theme);
    [ui->sidebarWebview loadHTMLString:sidebarHTML baseURL:nil];

    // Status bar
    ui->modeLabel = make_label(@" NORMAL ");
    ui->modeLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    ui->modeLabel.textColor = tc(ui->theme->bg);
    ui->modeLabel.backgroundColor = color_for_mode(ui, MODE_NORMAL);
    ui->modeLabel.drawsBackground = YES;
    ui->modeLabel.wantsLayer = YES;
    ui->modeLabel.layer.cornerRadius = 3;
    ui->modeLabel.layer.masksToBounds = YES;
    [ui->modeLabel setContentHuggingPriority:NSLayoutPriorityRequired
                              forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->urlLabel = make_label(@"");
    ui->urlLabel.textColor = tc(ui->theme->fg);
    ui->urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [ui->urlLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->progressLabel = make_label(@"");
    ui->progressLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    ui->progressLabel.textColor = tc(ui->theme->accent);
    [ui->progressLabel setContentHuggingPriority:NSLayoutPriorityRequired
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->pendingLabel = make_label(@"");
    ui->pendingLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    ui->pendingLabel.textColor = tc(ui->theme->bg);
    ui->pendingLabel.backgroundColor = tc(ui->theme->command);
    ui->pendingLabel.drawsBackground = YES;
    ui->pendingLabel.wantsLayer = YES;
    ui->pendingLabel.layer.cornerRadius = 3;
    ui->pendingLabel.layer.masksToBounds = YES;
    [ui->pendingLabel setContentHuggingPriority:NSLayoutPriorityRequired
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->statusBar = [NSStackView stackViewWithViews:@[ui->modeLabel, ui->urlLabel, ui->progressLabel, ui->pendingLabel]];
    ui->statusBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->statusBar.spacing = 8;
    ui->statusBar.edgeInsets = NSEdgeInsetsMake(4, 6, 4, 6);
    ui->statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    ui->statusBar.wantsLayer = YES;
    ui->statusBar.layer.backgroundColor = (tc(ui->theme->status_bg)).CGColor;

    // Command bar (hidden by default)
    ui->commandBar = [[NSTextField alloc] init];
    ui->commandBar.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    ui->commandBar.placeholderString = @"";
    ui->commandBar.bordered = YES;
    ui->commandBar.translatesAutoresizingMaskIntoConstraints = NO;

    ui->cmdDelegate = [[SwimCommandBarDelegate alloc] init];
    ui->cmdDelegate.callbacks = callbacks;
    ui->cmdDelegate.ui = ui;
    ui->commandBar.delegate = ui->cmdDelegate;

    // Command bar container with ":" prefix
    ui->colonLabel = make_label(@":");
    ui->colonLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightBold];
    ui->colonLabel.textColor = tc(ui->theme->command);
    ui->commandBarContainer = [NSStackView stackViewWithViews:@[ui->colonLabel, ui->commandBar]];
    ui->commandBarContainer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->commandBarContainer.spacing = 2;
    ui->commandBarContainer.edgeInsets = NSEdgeInsetsMake(2, 6, 2, 6);
    ui->commandBarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    ui->commandBarContainer.wantsLayer = YES;
    ui->commandBarContainer.layer.backgroundColor = (tc(ui->theme->status_bg)).CGColor;
    ui->commandBarContainer.hidden = YES;

    // Find bar (hidden by default)
    ui->findBar = [[NSTextField alloc] init];
    ui->findBar.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    ui->findBar.placeholderString = @"";
    ui->findBar.bordered = YES;
    ui->findBar.translatesAutoresizingMaskIntoConstraints = NO;

    ui->findDelegate = [[SwimFindBarDelegate alloc] init];
    ui->findDelegate.ui = ui;
    ui->findBar.delegate = ui->findDelegate;

    // Find bar container with "/" prefix
    NSTextField *slashLabel = make_label(@"/");
    slashLabel.textColor = tc(ui->theme->fg_dim);
    ui->findBarContainer = [NSStackView stackViewWithViews:@[slashLabel, ui->findBar]];
    ui->findBarContainer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->findBarContainer.spacing = 2;
    ui->findBarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    ui->findBarContainer.hidden = YES;

    // Root layout: tab bar, webview container, status bar, find bar, command bar
    ui->rootView = [[NSView alloc] init];
    ui->rootView.translatesAutoresizingMaskIntoConstraints = NO;

    // Separator between tab bar and webview
    ui->tabSeparator = [[NSView alloc] init];
    ui->tabSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    ui->tabSeparator.wantsLayer = YES;
    ui->tabSeparator.layer.backgroundColor = (tc(ui->theme->status_bg)).CGColor;

    [ui->rootView addSubview:ui->tabBarScroll];
    [ui->rootView addSubview:ui->tabSeparator];
    [ui->rootView addSubview:ui->contentSplit];
    [ui->rootView addSubview:ui->statusBar];
    [ui->rootView addSubview:ui->findBarContainer];
    [ui->rootView addSubview:ui->commandBarContainer];

    ui->window.contentView = ui->rootView;

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Tab bar at top
        [ui->tabBarScroll.topAnchor constraintEqualToAnchor:ui->rootView.topAnchor],
        [ui->tabBarScroll.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor
            constant:compact_titlebar ? 78 : 0],
        [ui->tabBarScroll.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Separator
        [ui->tabSeparator.topAnchor constraintEqualToAnchor:ui->tabBarScroll.bottomAnchor],
        [ui->tabSeparator.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->tabSeparator.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],
        [ui->tabSeparator.heightAnchor constraintEqualToConstant:1],

        // Content split fills middle (webview + sidebar)
        [ui->contentSplit.topAnchor constraintEqualToAnchor:ui->tabSeparator.bottomAnchor],
        [ui->contentSplit.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->contentSplit.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Status bar below content split
        [ui->statusBar.topAnchor constraintEqualToAnchor:ui->contentSplit.bottomAnchor],
        [ui->statusBar.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->statusBar.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Find bar below status bar
        [ui->findBarContainer.topAnchor constraintEqualToAnchor:ui->statusBar.bottomAnchor],
        [ui->findBarContainer.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->findBarContainer.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Command bar at bottom
        [ui->commandBarContainer.topAnchor constraintEqualToAnchor:ui->findBarContainer.bottomAnchor],
        [ui->commandBarContainer.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->commandBarContainer.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],
        [ui->commandBarContainer.bottomAnchor constraintEqualToAnchor:ui->rootView.bottomAnchor],
    ]];

    [ui->contentSplit setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationVertical];
    [ui->contentSplit setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationVertical];

    // Zero-height constraints for hidden bars (prevents bottom buffer)
    ui->cmdBarHeight = [ui->commandBarContainer.heightAnchor constraintEqualToConstant:0];
    ui->findBarHeight = [ui->findBarContainer.heightAnchor constraintEqualToConstant:0];
    ui->tabBarHeight = [ui->tabBarScroll.heightAnchor constraintEqualToConstant:0];
    ui->statusBarHeight = [ui->statusBar.heightAnchor constraintEqualToConstant:0];
    ui->cmdBarHeight.active = YES;
    ui->findBarHeight.active = YES;

    // Status bar visibility based on mode
    if (ui->status_bar_mode == 1) { // never
        ui->statusBar.hidden = YES;
        ui->statusBarHeight.active = YES;
    } else if (ui->status_bar_mode == 2) { // auto — start hidden
        ui->statusBar.hidden = YES;
        ui->statusBarHeight.active = YES;
    }

    [ui->window center];
    [ui->window makeKeyAndOrderFront:nil];

    // Terminate app when window is closed via GUI (red button / Cmd-W)
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
        object:ui->window
        queue:nil
        usingBlock:^(NSNotification *note) {
            (void)note;
            [NSApp terminate:nil];
        }];

    return ui;
}

int ui_add_tab(SwimUI *ui, const char *url, int tab_id, bool private_tab) {
    if (ui->tab_count >= MAX_TABS) return -1;

    SwimNavDelegate *nav = nil;
    WKWebView *wv = create_webview(ui, tab_id, private_tab, &nav);

    UITab *t = &ui->tabs[ui->tab_count];
    t->webview = wv;
    t->navDelegate = nav;
    t->tab_id = tab_id;
    t->private_tab = private_tab;

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

    // Stop media/loading, remove KVO observer and webview
    WKWebView *wv = ui->tabs[index].webview;
    [wv stopLoading];
    [wv loadHTMLString:@"" baseURL:nil];
    [wv removeObserver:ui->tabs[index].navDelegate forKeyPath:@"estimatedProgress"];
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
    for (int i = 0; i < ui->tab_count; i++) {
        if (ui->tabs[i].tab_id == tab_id) {
            if (title && title[0]) {
                snprintf(ui->tabs[i].title, sizeof(ui->tabs[i].title), "%s", title);
            }
            rebuild_tab_bar(ui);
            return;
        }
    }
}

void ui_move_tab(SwimUI *ui, int from, int to) {
    if (from < 0 || from >= ui->tab_count) return;
    if (to < 0 || to >= ui->tab_count) return;
    if (from == to) return;

    UITab tmp = ui->tabs[from];
    if (from < to) {
        for (int i = from; i < to; i++) ui->tabs[i] = ui->tabs[i + 1];
    } else {
        for (int i = from; i > to; i--) ui->tabs[i] = ui->tabs[i - 1];
    }
    ui->tabs[to] = tmp;

    ui->active_tab = to;
    rebuild_tab_bar(ui);
}

bool ui_tab_is_private(SwimUI *ui, int tab_id) {
    for (int i = 0; i < ui->tab_count; i++) {
        if (ui->tabs[i].tab_id == tab_id) return ui->tabs[i].private_tab;
    }
    return false;
}

void ui_navigate(SwimUI *ui, const char *url) {
    if (ui->active_tab < 0 || !url) return;

    // Block dangerous URL schemes at the navigation layer
    if (is_blocked_scheme(url)) return;

    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    NSString *urlStr = normalize_url([NSString stringWithUTF8String:url]);
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
    ui->modeLabel.stringValue = [NSString stringWithFormat:@" %s ", mode_name(mode)];
    ui->modeLabel.backgroundColor = color_for_mode(ui, mode);
    status_bar_flash(ui);
}

void ui_set_url(SwimUI *ui, const char *url) {
    ui->urlLabel.stringValue = [NSString stringWithUTF8String:url];
    status_bar_flash(ui);
}

void ui_set_progress(SwimUI *ui, double progress) {
    if (progress < 1.0) {
        ui->progressLabel.stringValue = [NSString stringWithFormat:@"[%d%%]", (int)(progress * 100)];
        status_bar_flash(ui);
    } else {
        ui->progressLabel.stringValue = @"";
    }
}

void ui_show_command_bar(SwimUI *ui, const char *prefix, const char *value, const char *placeholder) {
    // Store prefix for prepending on submit
    if (prefix && prefix[0]) {
        snprintf(ui->cmd_prefix, sizeof(ui->cmd_prefix), "%s", prefix);
        // Show ":open" or ":tabopen" in the label
        char display[64];
        snprintf(display, sizeof(display), ":%s", prefix);
        int len = (int)strlen(display);
        while (len > 0 && display[len - 1] == ' ') display[--len] = '\0';
        ui->colonLabel.stringValue = [NSString stringWithUTF8String:display];
    } else {
        ui->cmd_prefix[0] = '\0';
        ui->colonLabel.stringValue = @":";
    }

    // Set placeholder (visible when field is empty)
    if (placeholder && placeholder[0]) {
        ui->commandBar.placeholderString = [NSString stringWithUTF8String:placeholder];
    } else {
        ui->commandBar.placeholderString = @"";
    }

    ui->cmdBarHeight.active = NO;
    ui->commandBarContainer.hidden = NO;
    ui->commandBar.stringValue = value ? [NSString stringWithUTF8String:value] : @"";
    [ui->window makeFirstResponder:ui->commandBar];

    // Move cursor to end instead of selecting all
    if (value && value[0]) {
        NSText *editor = [ui->window fieldEditor:YES forObject:ui->commandBar];
        [editor setSelectedRange:NSMakeRange(editor.string.length, 0)];
    }
}

void ui_hide_command_bar(SwimUI *ui) {
    ui->commandBarContainer.hidden = YES;
    ui->cmdBarHeight.active = YES;
    ui->commandBar.stringValue = @"";
    ui->cmd_prefix[0] = '\0';
    if (ui->active_tab >= 0) {
        [ui->window makeFirstResponder:ui->tabs[ui->active_tab].webview];
    }
}

// --- Hint Mode ---

void ui_show_hints(SwimUI *ui, int mode) {
    if (ui->active_tab < 0) return;
    NSString *js = [NSString stringWithFormat:@"window.__swim_hints.show(%d)", mode];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

// Escape a string for safe embedding in a JS single-quoted string literal
static NSString *js_escape_string(NSString *s) {
    NSString *escaped = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    // Unicode line/paragraph separators (JS treats these as newlines)
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\\u2028"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\u2029" withString:@"\\u2029"];
    return escaped;
}

void ui_filter_hints(SwimUI *ui, const char *typed) {
    if (ui->active_tab < 0 || !typed) return;
    NSString *query = [NSString stringWithUTF8String:typed];
    NSString *escaped = js_escape_string(query);
    NSString *js = [NSString stringWithFormat:@"window.__swim_hints.filter('%@')", escaped];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

void ui_cancel_hints(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:@"window.__swim_hints.remove()"
                                      completionHandler:nil];
}

// --- Find in Page ---

void ui_show_find_bar(SwimUI *ui) {
    ui->findBarHeight.active = NO;
    ui->findBarContainer.hidden = NO;
    ui->findBar.stringValue = @"";
    [ui->window makeFirstResponder:ui->findBar];
}

void ui_hide_find_bar(SwimUI *ui) {
    ui->findBarContainer.hidden = YES;
    ui->findBarHeight.active = YES;
    ui->findBar.stringValue = @"";
    ui->find_query[0] = '\0';
    if (ui->active_tab >= 0) {
        // Clear highlights
        NSString *clearJS = @"window.getSelection().removeAllRanges()";
        [ui->tabs[ui->active_tab].webview evaluateJavaScript:clearJS completionHandler:nil];
        [ui->window makeFirstResponder:ui->tabs[ui->active_tab].webview];
    }
}

static void find_in_page(SwimUI *ui, bool backwards) {
    if (ui->active_tab < 0 || !ui->find_query[0]) return;
    NSString *escaped = js_escape_string([NSString stringWithUTF8String:ui->find_query]);
    NSString *js = [NSString stringWithFormat:
        @"window.find('%@', false, %@, true)", escaped, backwards ? @"true" : @"false"];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

void ui_find_next(SwimUI *ui) { find_in_page(ui, false); }
void ui_find_prev(SwimUI *ui) { find_in_page(ui, true); }

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

void ui_set_pending_keys(SwimUI *ui, const char *keys) {
    if (keys && keys[0]) {
        ui->pendingLabel.stringValue = [NSString stringWithFormat:@" %s ", keys];
        ui->pendingLabel.drawsBackground = YES;
        status_bar_flash(ui);
    } else {
        ui->pendingLabel.stringValue = @"";
        ui->pendingLabel.drawsBackground = NO;
    }
}

void ui_set_status_message(SwimUI *ui, const char *msg) {
    status_bar_flash(ui);
    // Only save the real URL on the first message (gen was 0)
    if (ui->status_msg_gen == 0) {
        snprintf(ui->saved_url, sizeof(ui->saved_url), "%s",
            [ui->urlLabel.stringValue UTF8String]);
    }
    int gen = ++ui->status_msg_gen;
    ui->urlLabel.stringValue = [NSString stringWithUTF8String:msg];
    ui->urlLabel.textColor = [NSColor colorWithSRGBRed:0.9 green:0.4 blue:0.4 alpha:1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (ui->status_msg_gen == gen) {
                ui->status_msg_gen = 0;
                ui->urlLabel.stringValue = [NSString stringWithUTF8String:ui->saved_url];
                ui->urlLabel.textColor = tc(ui->theme->fg);
            }
        });
}

void ui_zoom_in(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    wv.pageZoom = fmin(wv.pageZoom + 0.1, 3.0);
}

void ui_zoom_out(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    wv.pageZoom = fmax(wv.pageZoom - 0.1, 0.3);
}

void ui_zoom_reset(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    ui->tabs[ui->active_tab].webview.pageZoom = 1.0;
}

void ui_set_window_title(SwimUI *ui, const char *title) {
    if (title && title[0]) {
        ui->window.title = [NSString stringWithFormat:@"%s — swim",
            title];
    } else {
        ui->window.title = @"swim";
    }
}

void ui_set_tab_bar_mode(SwimUI *ui, const char *mode) {
    ui->tab_bar_mode = parse_bar_mode(mode);
    rebuild_tab_bar(ui);
}

void ui_set_status_bar_mode(SwimUI *ui, const char *mode) {
    ui->status_bar_mode = parse_bar_mode(mode);

    if (ui->status_bar_mode == 0) { // always — show immediately
        ui->statusBar.hidden = NO;
        ui->statusBarHeight.active = NO;
    } else if (ui->status_bar_mode == 1) { // never — hide immediately
        ui->statusBar.hidden = YES;
        ui->statusBarHeight.active = YES;
    } else { // auto — hide, will flash on next event
        ui->statusBar.hidden = YES;
        ui->statusBarHeight.active = YES;
    }
}

void ui_set_userscripts(SwimUI *ui, UserScriptManager *scripts) {
    ui->userscripts = scripts;
}

// --- Private API declarations for mute and inspector ---

@interface WKWebView (SwimPrivate)
- (void)_setPageMuted:(NSUInteger)state;
- (BOOL)_isPlayingAudio;
- (id)_inspector;
@end

@interface NSObject (SwimInspector)
- (void)show;
@end

void ui_set_dark_mode(SwimUI *ui, bool enabled) {
    NSAppearance *appearance = enabled
        ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
        : [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    for (int i = 0; i < ui->tab_count; i++) {
        ui->tabs[i].webview.appearance = appearance;
    }
    // Store for new tabs
    ui->window.appearance = appearance;
}

void ui_toggle_mute(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    if ([wv respondsToSelector:@selector(_setPageMuted:)]) {
        // Toggle: 0=unmuted, 1=audio muted
        static bool muted = false;
        muted = !muted;
        [wv _setPageMuted:muted ? 1 : 0];
        ui_set_status_message(ui, muted ? "Tab muted" : "Tab unmuted");
    } else {
        ui_set_status_message(ui, "Mute not available");
    }
}

void ui_open_inspector(SwimUI *ui) {
    if (ui->active_tab < 0) return;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    if ([wv respondsToSelector:@selector(_inspector)]) {
        id inspector = [wv _inspector];
        if ([inspector respondsToSelector:@selector(show)]) {
            [inspector show];
        }
    } else {
        ui_set_status_message(ui, "Inspector not available");
    }
}

void ui_set_proxy(SwimUI *ui, const char *type, const char *host, int port) {
    (void)ui;
    // Proxy applies to the default data store for future navigations
    if (!type || strcmp(type, "none") == 0 || !host || !host[0]) {
        // Clear proxy — use default data store without proxy config
        WKWebsiteDataStore *store = [WKWebsiteDataStore defaultDataStore];
        if ([store respondsToSelector:@selector(setProxyConfigurations:)]) {
            [store setProxyConfigurations:@[]];
        }
        ui_set_status_message(ui, "Proxy disabled");
        return;
    }

    if (@available(macOS 14.0, *)) {
        char port_str[8];
        snprintf(port_str, sizeof(port_str), "%d", port);
        nw_endpoint_t endpoint = nw_endpoint_create_host(host, port_str);

        nw_proxy_config_t proxy = NULL;
        if (strcmp(type, "http") == 0 || strcmp(type, "https") == 0) {
            proxy = nw_proxy_config_create_http_connect(endpoint, NULL);
        } else if (strcmp(type, "socks5") == 0) {
            proxy = nw_proxy_config_create_socksv5(endpoint);
        }

        if (proxy) {
            WKWebsiteDataStore *store = [WKWebsiteDataStore defaultDataStore];
            store.proxyConfigurations = @[proxy];
            char msg[256];
            snprintf(msg, sizeof(msg), "Proxy: %s %s:%d", type, host, port);
            ui_set_status_message(ui, msg);
        }
    } else {
        ui_set_status_message(ui, "Proxy requires macOS 14+");
    }
}

void ui_close(SwimUI *ui) {
    // Stop all media/loading before closing
    for (int i = 0; i < ui->tab_count; i++) {
        WKWebView *wv = ui->tabs[i].webview;
        [wv stopLoading];
        [wv loadHTMLString:@"" baseURL:nil];
    }
    [ui->window close];
    [NSApp terminate:nil];
}

void *ui_screenshot(SwimUI *ui) {
    // Capture the full window content (tab bar, status bar, webview, command bar).
    // We composite: render the NSView hierarchy for chrome, then overlay the
    // WKWebView snapshot (since WKWebView doesn't render via displayRectIgnoringOpacity).
    NSView *contentView = ui->window.contentView;
    NSRect bounds = contentView.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return NULL;

    // Step 1: Capture the WKWebView content
    __block NSImage *webviewImage = nil;
    __block BOOL done = NO;

    if (ui->active_tab >= 0 && ui->active_tab < ui->tab_count) {
        WKWebView *wv = ui->tabs[ui->active_tab].webview;
        if (wv) {
            WKSnapshotConfiguration *config = [[WKSnapshotConfiguration alloc] init];
            [wv takeSnapshotWithConfiguration:config
                            completionHandler:^(NSImage *image, NSError *error) {
                (void)error;
                webviewImage = image;
                done = YES;
            }];

            NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
            while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                    beforeDate:timeout]) {
                if ([timeout timeIntervalSinceNow] <= 0) break;
            }
        }
    }

    // Step 2: Render full view hierarchy into a bitmap
    NSBitmapImageRep *rep = [contentView bitmapImageRepForCachingDisplayInRect:bounds];
    if (!rep) return NULL;
    [contentView cacheDisplayInRect:bounds toBitmapImageRep:rep];

    // Step 3: Composite the webview snapshot over the webview area
    // (cacheDisplayInRect renders NSViews but WKWebView renders blank)
    if (webviewImage) {
        NSRect wvFrame = [ui->webviewContainer convertRect:ui->webviewContainer.bounds
                                                    toView:contentView];
        NSImage *composite = [[NSImage alloc] initWithSize:bounds.size];
        [composite lockFocus];

        // Draw the view hierarchy render
        [rep drawInRect:bounds];

        // Draw the webview snapshot in the webview container's frame
        [webviewImage drawInRect:wvFrame
                        fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver
                        fraction:1.0];

        [composite unlockFocus];

        // Convert composite to PNG
        NSData *tiff = [composite TIFFRepresentation];
        NSBitmapImageRep *finalRep = [[NSBitmapImageRep alloc] initWithData:tiff];
        NSData *result = [finalRep representationUsingType:NSBitmapImageFileTypePNG
                                               properties:@{}];
        return (__bridge_retained void *)result;
    }

    // No webview — just return the view hierarchy render
    NSData *result = [rep representationUsingType:NSBitmapImageFileTypePNG
                                       properties:@{}];
    return (__bridge_retained void *)result;
}

void *ui_get_window(SwimUI *ui) {
    return (__bridge void *)ui->window;
}

bool ui_is_loading(SwimUI *ui) {
    if (ui->active_tab < 0 || ui->active_tab >= ui->tab_count) return false;
    WKWebView *wv = ui->tabs[ui->active_tab].webview;
    return wv ? [wv isLoading] : false;
}

void *ui_get_active_webview(SwimUI *ui) {
    if (ui->active_tab < 0 || ui->active_tab >= ui->tab_count) return NULL;
    return (__bridge void *)ui->tabs[ui->active_tab].webview;
}

void ui_set_serving(SwimUI *ui, bool serving) {
    ui->serving = serving;
    if (serving && !ui->dialog_queue) {
        ui->dialog_queue = [NSMutableArray new];
    }
}

void *ui_get_dialog_queue(SwimUI *ui) {
    if (!ui->dialog_queue) ui->dialog_queue = [NSMutableArray new];
    return (__bridge void *)ui->dialog_queue;
}

// --- AI Sidebar ---

void ui_show_sidebar(SwimUI *ui) {
    if (ui->sidebar_visible) return;
    ui->sidebar_visible = true;
    ui->sidebarContainer.hidden = NO;
    ui->sidebarSeparator.hidden = NO;
    ui->sidebarZeroWidth.active = NO;
    ui->sidebarWidth.active = YES;
    [ui->window makeFirstResponder:ui->sidebarWebview];
    [ui->sidebarWebview evaluateJavaScript:@"focusInput()" completionHandler:nil];
}

void ui_hide_sidebar(SwimUI *ui) {
    if (!ui->sidebar_visible) return;
    ui->sidebar_visible = false;
    ui->sidebarWidth.active = NO;
    ui->sidebarZeroWidth.active = YES;
    ui->sidebarContainer.hidden = YES;
    ui->sidebarSeparator.hidden = YES;
    // Return focus to window (not webview — avoids spurious focus events)
    [ui->window makeFirstResponder:nil];
}

void ui_toggle_sidebar(SwimUI *ui) {
    if (ui->sidebar_visible) {
        ui_hide_sidebar(ui);
    } else {
        ui_show_sidebar(ui);
    }
}

bool ui_sidebar_visible(SwimUI *ui) {
    return ui->sidebar_visible;
}

void ui_sidebar_submit(SwimUI *ui, const char *prompt) {
    ui_show_sidebar(ui);
    NSString *escaped = [[NSString stringWithUTF8String:prompt]
        stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    // Directly call JS functions instead of simulating keypress
    NSString *js = [NSString stringWithFormat:
        @"addMessage('user', '%@');"
        "showThinking();"
        "window.webkit.messageHandlers.swim.postMessage("
        "  {type:'sidebar-prompt', text:'%@'}"
        ");", escaped, escaped];
    [ui->sidebarWebview evaluateJavaScript:js completionHandler:nil];
}
