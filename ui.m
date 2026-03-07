#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include "ui.h"

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

// --- SwimUI ---

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
    }
}
@end

struct SwimUI {
    NSWindow *window;
    WKWebView *webview;
    NSTextField *modeLabel;
    NSTextField *urlLabel;
    NSTextField *commandBar;
    NSStackView *statusBar;
    NSStackView *rootStack;
    SwimCommandBarDelegate *cmdDelegate;
    SwimNavDelegate *navDelegate;
    SwimScriptHandler *scriptHandler;
    UICallbacks callbacks;
};

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

SwimUI *ui_create(UICallbacks callbacks) {
    SwimUI *ui = calloc(1, sizeof(SwimUI));
    ui->callbacks = callbacks;

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

    // WebView with script handler for focus detection
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    ui->scriptHandler = [[SwimScriptHandler alloc] init];
    ui->scriptHandler.callbacks = callbacks;
    [config.userContentController addScriptMessageHandler:ui->scriptHandler name:@"swim"];

    // Inject focus detection JS
    NSString *focusJS = @"document.addEventListener('focusin', function(e) {"
        "var t = e.target.tagName;"
        "if (t === 'INPUT' || t === 'TEXTAREA' || e.target.isContentEditable) {"
        "  window.webkit.messageHandlers.swim.postMessage({type:'focus',focused:true});"
        "}"
        "});"
        "document.addEventListener('focusout', function(e) {"
        "  window.webkit.messageHandlers.swim.postMessage({type:'focus',focused:false});"
        "});";
    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:focusJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:script];

    ui->webview = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    ui->webview.translatesAutoresizingMaskIntoConstraints = NO;

    // Navigation delegate
    ui->navDelegate = [[SwimNavDelegate alloc] init];
    ui->navDelegate.callbacks = callbacks;
    ui->navDelegate.tabId = 1;  // first tab
    ui->webview.navigationDelegate = ui->navDelegate;

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

    // Root layout: webview on top, status bar, command bar at bottom
    ui->rootStack = [NSStackView stackViewWithViews:@[ui->webview, ui->statusBar, ui->commandBar]];
    ui->rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    ui->rootStack.spacing = 0;
    ui->rootStack.translatesAutoresizingMaskIntoConstraints = NO;

    ui->window.contentView = ui->rootStack;

    // Constraints: webview fills available space
    [NSLayoutConstraint activateConstraints:@[
        [ui->webview.leadingAnchor constraintEqualToAnchor:ui->rootStack.leadingAnchor],
        [ui->webview.trailingAnchor constraintEqualToAnchor:ui->rootStack.trailingAnchor],
        [ui->statusBar.leadingAnchor constraintEqualToAnchor:ui->rootStack.leadingAnchor],
        [ui->statusBar.trailingAnchor constraintEqualToAnchor:ui->rootStack.trailingAnchor],
        [ui->commandBar.leadingAnchor constraintEqualToAnchor:ui->rootStack.leadingAnchor],
        [ui->commandBar.trailingAnchor constraintEqualToAnchor:ui->rootStack.trailingAnchor],
    ]];

    // Let webview fill remaining space
    [ui->webview setContentHuggingPriority:NSLayoutPriorityDefaultLow
                            forOrientation:NSLayoutConstraintOrientationVertical];
    [ui->statusBar setContentHuggingPriority:NSLayoutPriorityRequired
                              forOrientation:NSLayoutConstraintOrientationVertical];

    [ui->window makeKeyAndOrderFront:nil];

    return ui;
}

void ui_navigate(SwimUI *ui, const char *url) {
    NSString *urlStr = [NSString stringWithUTF8String:url];
    // Add https:// if no scheme
    if (![urlStr hasPrefix:@"http://"] && ![urlStr hasPrefix:@"https://"] && ![urlStr hasPrefix:@"about:"]) {
        urlStr = [@"https://" stringByAppendingString:urlStr];
    }
    NSURL *nsurl = [NSURL URLWithString:urlStr];
    if (nsurl) {
        [ui->webview loadRequest:[NSURLRequest requestWithURL:nsurl]];
    }
}

void ui_run_js(SwimUI *ui, const char *js) {
    NSString *jsStr = [NSString stringWithUTF8String:js];
    [ui->webview evaluateJavaScript:jsStr completionHandler:nil];
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
    [ui->window makeFirstResponder:ui->webview];
}

void ui_close(SwimUI *ui) {
    [ui->window close];
    [NSApp terminate:nil];
}
