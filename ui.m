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
    case MODE_NORMAL:      return [NSColor colorWithSRGBRed:0.45 green:0.70 blue:0.45 alpha:1];
    case MODE_INSERT:      return [NSColor colorWithSRGBRed:0.45 green:0.55 blue:0.85 alpha:1];
    case MODE_COMMAND:     return [NSColor colorWithSRGBRed:0.82 green:0.75 blue:0.40 alpha:1];
    case MODE_HINT:        return [NSColor colorWithSRGBRed:0.90 green:0.55 blue:0.25 alpha:1];
    case MODE_PASSTHROUGH: return [NSColor colorWithSRGBRed:0.65 green:0.45 blue:0.78 alpha:1];
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
@property (assign) SwimUI *ui;
@end

@interface SwimNavDelegate : NSObject <WKNavigationDelegate>
@property (assign) UICallbacks callbacks;
@property (assign) int tabId;
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
        if (self.callbacks.on_hints_done) {
            self.callbacks.on_hints_done(self.callbacks.ctx);
        }
    }
}
@end

// --- Tab Entry (UI-side per-tab state) ---

typedef struct UITab {
    WKWebView *webview;
    SwimNavDelegate *navDelegate;
    int tab_id;
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
        // Tab completion — only in raw command mode (no prefix)
        if (!self.ui->cmd_prefix[0] && self.callbacks.on_command_complete) {
            NSTextField *field = (NSTextField *)control;
            const char *text = [field.stringValue UTF8String];
            if (text && text[0]) {
                const char *completed = self.callbacks.on_command_complete(text, self.callbacks.ctx);
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
    NSURL *url = navigationAction.request.URL;
    if (url && self.ui->callbacks.on_command_submit) {
        char cmd[4096];
        snprintf(cmd, sizeof(cmd), "tabopen %s", [url.absoluteString UTF8String]);
        self.ui->callbacks.on_command_submit(cmd, self.ui->callbacks.ctx);
    }
    return nil;
}

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                     initiatedByFrame:(WKFrameInfo *)frame
                    completionHandler:(void (^)(void))completionHandler {
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
        ui_set_status_message(self.ui, "Download failed");
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

        NSString *label = [NSString stringWithFormat:@" %d %@ ", i + 1, title];

        SwimTabButton *btn = [SwimTabButton buttonWithTitle:label
            target:sTabBarHandler action:@selector(tabButtonClicked:)];
        btn.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        btn.bordered = NO;
        btn.bezelStyle = NSBezelStyleAccessoryBarAction;
        btn.tabIndex = i;
        btn.tabId = t->tab_id;
        btn.wantsLayer = YES;

        if (i == ui->active_tab) {
            btn.contentTintColor = [NSColor colorWithSRGBRed:0.90 green:0.90 blue:0.90 alpha:1];
            btn.layer.backgroundColor = [NSColor colorWithSRGBRed:0.22 green:0.22 blue:0.25 alpha:1].CGColor;
            // Bottom border via sublayer
            CALayer *border = [CALayer layer];
            border.frame = CGRectMake(0, 0, 2000, 2);  // Width stretches, positioned at bottom
            border.backgroundColor = color_for_mode(MODE_NORMAL).CGColor;
            border.name = @"tabBorder";
            [btn.layer addSublayer:border];
        } else {
            btn.contentTintColor = [NSColor colorWithSRGBRed:0.45 green:0.45 blue:0.45 alpha:1];
            btn.layer.backgroundColor = [NSColor clearColor].CGColor;
        }

        [btn setContentHuggingPriority:NSLayoutPriorityRequired
                        forOrientation:NSLayoutConstraintOrientationHorizontal];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn.heightAnchor constraintEqualToConstant:28].active = YES;
        [ui->tabBar addArrangedSubview:btn];
    }
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
    "function show(nt){"
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
    "    hints.push({el:cl[i].el,label:lb[i],ov:o,nt:!!nt})}}"
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
    "  if(h.nt){"
    "    var href=h.el.href||(h.el.closest&&h.el.closest('a[href]')&&h.el.closest('a[href]').href);"
    "    if(href)window.webkit.messageHandlers.swim.postMessage({type:'hint-activate',url:href,newTab:true})"
    "  }else{"
    "    h.el.click();"
    "    if(h.el.tagName==='INPUT'||h.el.tagName==='TEXTAREA'||h.el.tagName==='SELECT')h.el.focus()}"
    "  window.webkit.messageHandlers.swim.postMessage({type:'hints-done'})}"
    "function rm(){if(box){box.remove();box=null}hints=[]}"
    "window.__swim_hints={show:show,filter:filter,remove:function(){rm();"
    "  window.webkit.messageHandlers.swim.postMessage({type:'hints-cancelled'})}};"
    "})();";

// Early CSS injection — runs before page renders to prevent flash
static NSString *const kOldRedditCSS =
    @"(function(){"
    "if(window.location.hostname!=='old.reddit.com')return;"
    "var s=document.createElement('style');"
    "s.textContent='"
    ".sponsorlink,.promoted,.promotedlink{display:none!important}"
    "#siteTable_organic{display:none!important}"
    ".infobar.listingsignupbar{display:none!important}"
    ".premium-banner-outer,.goldvertisement,.ad-container{display:none!important}"
    ".spacer .premium-banner,.spacer .gold-accent{display:none!important}"
    ".side{overflow:hidden}"
    ".side.swim-hidden{width:0!important;opacity:0;padding:0!important;margin:0!important}"
    ".side.swim-animate,.side.swim-animate~.content,.side.swim-animate+.content{transition:all 0.2s}"
    ".side.swim-hidden~.content,.side.swim-hidden+.content{margin-right:20px!important}"
    "';"
    "(document.head||document.documentElement).appendChild(s);"
    "try{if(localStorage.getItem('swim-sidebar-hidden')==='1'){"
    "document.documentElement.classList.add('swim-sidebar-will-hide');"
    "s.textContent+='.side{width:0!important;opacity:0;padding:0!important;margin:0!important}'"
    "+'.content{margin-right:20px!important}';"
    "}}catch(e){}"
    "})();";

// Late JS — runs after DOM is ready to add toggle button
static NSString *const kOldRedditJS =
    @"(function(){"
    "if(window.location.hostname!=='old.reddit.com')return;"
    "function setup(){"
    "if(document.getElementById('swim-sidebar-btn'))return;"
    "var side=document.querySelector('.side');"
    "if(!side)return false;"
    "var hidden=localStorage.getItem('swim-sidebar-hidden')==='1';"
    "if(hidden){side.classList.add('swim-hidden')}"
    "var btn=document.createElement('div');"
    "btn.id='swim-sidebar-btn';"
    "btn.textContent=hidden?'\\u00BB':'\\u00AB';"
    "btn.style.cssText='position:fixed;right:16px;top:50%;transform:translateY(-50%);"
    "z-index:9999;cursor:pointer;font-size:16px;color:#666;background:#1a1a1a;"
    "border:1px solid #333;border-radius:4px;"
    "padding:12px 6px;user-select:none;opacity:0;transition:opacity 0.3s';"
    "setTimeout(function(){btn.style.opacity='1'},100);"
    "btn.title='Toggle sidebar';"
    "btn.addEventListener('click',function(){"
    "var s=document.querySelector('.side');"
    "if(!s)return;"
    "s.classList.add('swim-animate');"
    "s.classList.toggle('swim-hidden');"
    "var h=s.classList.contains('swim-hidden');"
    "btn.textContent=h?'\\u00BB':'\\u00AB';"
    "localStorage.setItem('swim-sidebar-hidden',h?'1':'0');"
    "});"
    "document.body.appendChild(btn);"
    "return true;"
    "}"
    "if(setup())return;"
    "var n=0;"
    "var iv=setInterval(function(){if(setup()||++n>=20)clearInterval(iv)},250);"
    "})();";

// YouTube ad cleanup — hides ad overlays, skips video ads, removes companion ads
static NSString *const kYouTubeAdBlockJS =
    @"(function(){"
    "if(window.location.hostname!=='www.youtube.com'"
    "&&window.location.hostname!=='m.youtube.com')return;"

    // CSS to hide ad-related elements
    "var s=document.createElement('style');"
    "s.textContent='"
    ".ad-showing .video-ads,"
    ".ytp-ad-module,"
    ".ytp-ad-overlay-container,"
    ".ytp-ad-text-overlay,"
    ".ytd-promoted-sparkles-web-renderer,"
    ".ytd-display-ad-renderer,"
    ".ytd-companion-slot-renderer,"
    ".ytd-action-companion-ad-renderer,"
    ".ytd-in-feed-ad-layout-renderer,"
    ".ytd-ad-slot-renderer,"
    ".ytd-banner-promo-renderer,"
    ".ytd-statement-banner-renderer,"
    ".ytd-masthead-ad-renderer,"
    "#player-ads,"
    "#masthead-ad,"
    ".ytd-merch-shelf-renderer,"
    ".ytd-engagement-panel-section-list-renderer[target-id=engagement-panel-ads]"
    "{display:none!important}';"
    "document.head.appendChild(s);"

    // Skip video ads: click skip button or fast-forward ad
    "var observer=new MutationObserver(function(){"
    "var skip=document.querySelector('.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad-button');"
    "if(skip){skip.click();return}"
    "var v=document.querySelector('.ad-showing video');"
    "if(v&&v.duration&&v.duration>0){v.currentTime=v.duration}"
    "});"
    "observer.observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['class']});"
    "})();";

// --- WebView Factory ---

static WKWebView *create_webview(SwimUI *ui, int tab_id, SwimNavDelegate **out_nav) {
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.preferences.elementFullscreenEnabled = YES;
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

    // old.reddit.com — early CSS (before render)
    WKUserScript *redditCSS = [[WKUserScript alloc]
        initWithSource:kOldRedditCSS
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:redditCSS];

    // old.reddit.com — toggle button (after DOM ready)
    WKUserScript *redditScript = [[WKUserScript alloc]
        initWithSource:kOldRedditJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:redditScript];

    // YouTube ad blocking
    WKUserScript *ytAdBlock = [[WKUserScript alloc]
        initWithSource:kYouTubeAdBlockJS
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [config.userContentController addUserScript:ytAdBlock];

    // Apply content blocking if enabled
    if (ui->adblock_enabled && ui->blockRuleList) {
        [config.userContentController addContentRuleList:ui->blockRuleList];
    }

    WKWebView *wv = [[WKWebView alloc] initWithFrame:ui->webviewContainer.bounds configuration:config];
    wv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    wv.customUserAgent = kUserAgent;
    wv.allowsBackForwardNavigationGestures = YES;

    SwimNavDelegate *nav = [[SwimNavDelegate alloc] init];
    nav.callbacks = ui->callbacks;
    nav.tabId = tab_id;
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

static void tab_bar_clicked(SwimUI *ui, int index) {
    if (ui->callbacks.on_tab_selected) {
        ui->callbacks.on_tab_selected(index, ui->callbacks.ctx);
    }
}

// --- Public API ---

SwimUI *ui_create(UICallbacks callbacks, bool compact_titlebar) {
    SwimUI *ui = calloc(1, sizeof(SwimUI));
    ui->callbacks = callbacks;
    ui->active_tab = -1;

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
    ui->window.backgroundColor = [NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.14 alpha:1];
    if (compact_titlebar) {
        ui->window.titlebarAppearsTransparent = YES;
        ui->window.titleVisibility = NSWindowTitleHidden;
    }

    // Script handler (shared across all tabs)
    ui->scriptHandler = [[SwimScriptHandler alloc] init];
    ui->scriptHandler.callbacks = callbacks;

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
    ui->tabBarScroll.backgroundColor = [NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.14 alpha:1];
    [NSLayoutConstraint activateConstraints:@[
        [ui->tabBarScroll.heightAnchor constraintEqualToConstant:28],
    ]];

    // WebView container (plain NSView, webviews get added/removed as children)
    ui->webviewContainer = [[NSView alloc] init];
    ui->webviewContainer.translatesAutoresizingMaskIntoConstraints = NO;

    // Status bar
    ui->modeLabel = make_label(@" NORMAL ");
    ui->modeLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    ui->modeLabel.textColor = [NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.10 alpha:1];
    ui->modeLabel.backgroundColor = color_for_mode(MODE_NORMAL);
    ui->modeLabel.drawsBackground = YES;
    ui->modeLabel.wantsLayer = YES;
    ui->modeLabel.layer.cornerRadius = 3;
    ui->modeLabel.layer.masksToBounds = YES;
    [ui->modeLabel setContentHuggingPriority:NSLayoutPriorityRequired
                              forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->urlLabel = make_label(@"");
    ui->urlLabel.textColor = [NSColor colorWithSRGBRed:0.67 green:0.67 blue:0.67 alpha:1];
    ui->urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [ui->urlLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->progressLabel = make_label(@"");
    ui->progressLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    ui->progressLabel.textColor = [NSColor colorWithSRGBRed:0.5 green:0.7 blue:0.9 alpha:1];
    [ui->progressLabel setContentHuggingPriority:NSLayoutPriorityRequired
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];

    ui->pendingLabel = make_label(@"");
    ui->pendingLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    ui->pendingLabel.textColor = [NSColor colorWithSRGBRed:0.08 green:0.08 blue:0.10 alpha:1];
    ui->pendingLabel.backgroundColor = [NSColor colorWithSRGBRed:0.80 green:0.75 blue:0.45 alpha:1];
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
    ui->statusBar.layer.backgroundColor = [NSColor colorWithSRGBRed:0.13 green:0.13 blue:0.15 alpha:1].CGColor;

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
    ui->colonLabel.textColor = [NSColor colorWithSRGBRed:0.82 green:0.75 blue:0.40 alpha:1];
    ui->commandBarContainer = [NSStackView stackViewWithViews:@[ui->colonLabel, ui->commandBar]];
    ui->commandBarContainer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->commandBarContainer.spacing = 2;
    ui->commandBarContainer.edgeInsets = NSEdgeInsetsMake(2, 6, 2, 6);
    ui->commandBarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    ui->commandBarContainer.wantsLayer = YES;
    ui->commandBarContainer.layer.backgroundColor = [NSColor colorWithSRGBRed:0.10 green:0.10 blue:0.12 alpha:1].CGColor;
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
    slashLabel.textColor = [NSColor colorWithSRGBRed:0.7 green:0.7 blue:0.7 alpha:1];
    ui->findBarContainer = [NSStackView stackViewWithViews:@[slashLabel, ui->findBar]];
    ui->findBarContainer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ui->findBarContainer.spacing = 2;
    ui->findBarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    ui->findBarContainer.hidden = YES;

    // Root layout: tab bar, webview container, status bar, find bar, command bar
    ui->rootView = [[NSView alloc] init];
    ui->rootView.translatesAutoresizingMaskIntoConstraints = NO;

    // Separator between tab bar and webview
    NSView *tabSeparator = [[NSView alloc] init];
    tabSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    tabSeparator.wantsLayer = YES;
    tabSeparator.layer.backgroundColor = [NSColor colorWithSRGBRed:0.22 green:0.22 blue:0.25 alpha:1].CGColor;

    [ui->rootView addSubview:ui->tabBarScroll];
    [ui->rootView addSubview:tabSeparator];
    [ui->rootView addSubview:ui->webviewContainer];
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
        [tabSeparator.topAnchor constraintEqualToAnchor:ui->tabBarScroll.bottomAnchor],
        [tabSeparator.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [tabSeparator.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],
        [tabSeparator.heightAnchor constraintEqualToConstant:1],

        // WebView container fills middle
        [ui->webviewContainer.topAnchor constraintEqualToAnchor:tabSeparator.bottomAnchor],
        [ui->webviewContainer.leadingAnchor constraintEqualToAnchor:ui->rootView.leadingAnchor],
        [ui->webviewContainer.trailingAnchor constraintEqualToAnchor:ui->rootView.trailingAnchor],

        // Status bar below webview
        [ui->statusBar.topAnchor constraintEqualToAnchor:ui->webviewContainer.bottomAnchor],
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

    [ui->webviewContainer setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationVertical];
    [ui->webviewContainer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                  forOrientation:NSLayoutConstraintOrientationVertical];

    // Zero-height constraints for hidden bars (prevents bottom buffer)
    ui->cmdBarHeight = [ui->commandBarContainer.heightAnchor constraintEqualToConstant:0];
    ui->findBarHeight = [ui->findBarContainer.heightAnchor constraintEqualToConstant:0];
    ui->cmdBarHeight.active = YES;
    ui->findBarHeight.active = YES;

    [ui->window center];
    [ui->window makeKeyAndOrderFront:nil];

    return ui;
}

int ui_add_tab(SwimUI *ui, const char *url, int tab_id) {
    if (ui->tab_count >= MAX_TABS) return -1;

    SwimNavDelegate *nav = nil;
    WKWebView *wv = create_webview(ui, tab_id, &nav);

    UITab *t = &ui->tabs[ui->tab_count];
    t->webview = wv;
    t->navDelegate = nav;
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
    ui->modeLabel.stringValue = [NSString stringWithFormat:@" %s ", mode_name(mode)];
    ui->modeLabel.backgroundColor = color_for_mode(mode);
}

void ui_set_url(SwimUI *ui, const char *url) {
    ui->urlLabel.stringValue = [NSString stringWithUTF8String:url];
}

void ui_set_progress(SwimUI *ui, double progress) {
    if (progress < 1.0) {
        ui->progressLabel.stringValue = [NSString stringWithFormat:@"[%d%%]", (int)(progress * 100)];
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

void ui_find_next(SwimUI *ui) {
    if (ui->active_tab < 0 || !ui->find_query[0]) return;
    NSString *query = [NSString stringWithUTF8String:ui->find_query];
    NSString *escaped = [query stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:
        @"window.find('%@', false, false, true)", escaped];
    [ui->tabs[ui->active_tab].webview evaluateJavaScript:js completionHandler:nil];
}

void ui_find_prev(SwimUI *ui) {
    if (ui->active_tab < 0 || !ui->find_query[0]) return;
    NSString *query = [NSString stringWithUTF8String:ui->find_query];
    NSString *escaped = [query stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:
        @"window.find('%@', false, true, true)", escaped];
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

void ui_set_pending_keys(SwimUI *ui, const char *keys) {
    if (keys && keys[0]) {
        ui->pendingLabel.stringValue = [NSString stringWithFormat:@" %s ", keys];
        ui->pendingLabel.drawsBackground = YES;
    } else {
        ui->pendingLabel.stringValue = @"";
        ui->pendingLabel.drawsBackground = NO;
    }
}

void ui_set_status_message(SwimUI *ui, const char *msg) {
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
                ui->urlLabel.textColor = [NSColor colorWithSRGBRed:0.67 green:0.67 blue:0.67 alpha:1];
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

#ifdef SWIM_TEST
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
        // Flip Y for bitmap drawing (NSView is flipped in bitmap context)
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
#endif
