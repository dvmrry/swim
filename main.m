#import <Cocoa/Cocoa.h>
#include "browser.h"
#include "input.h"
#include "commands.h"
#include "ui.h"
#include "storage.h"
#include "config.h"
#ifdef SWIM_TEST
#include "test_server.h"
#endif

// --- App State ---

typedef struct App {
    Browser browser;
    ModeManager mode;
    CommandRegistry commands;
    SwimUI *ui;
    Storage bookmarks;
    Storage history;
    Config config;
    char session_path[512];
    char config_path[512];
} App;

static App app;

// --- Helpers ---

static void set_url_with_tls(const char *url) {
    if (url && strncmp(url, "https://", 8) == 0) {
        char display[2200];
        snprintf(display, sizeof(display), "\xF0\x9F\x94\x92 %s", url);  // lock emoji
        ui_set_url(app.ui, display);
    } else {
        ui_set_url(app.ui, url ? url : "");
    }
}

static void open_url_in_active_tab(const char *raw) {
    if (!raw || !raw[0]) return;

    // If no dots or slashes, treat as search
    if (!strchr(raw, '.') && !strchr(raw, '/') && strncmp(raw, "http", 4) != 0) {
        char search_url[4096];
        // Use config search engine, replace %s with query
        const char *fmt = app.config.search_engine;
        char *pct = strstr(fmt, "%s");
        if (pct) {
            int prefix_len = (int)(pct - fmt);
            snprintf(search_url, sizeof(search_url), "%.*s%s%s",
                prefix_len, fmt, raw, pct + 2);
        } else {
            snprintf(search_url, sizeof(search_url), "%s%s", fmt, raw);
        }
        ui_navigate(app.ui, search_url);
    } else {
        ui_navigate(app.ui, raw);
    }
}

static void create_tab(const char *url) {
    int tab_id = browser_add_tab(&app.browser, url ? url : "");
    ui_add_tab(app.ui, url, tab_id);

    Tab *t = browser_active(&app.browser);
    if (t && t->url[0]) {
        set_url_with_tls(t->url);
    } else {
        ui_set_url(app.ui, "");
    }
}

static void sync_tab_display(void) {
    Tab *t = browser_active(&app.browser);
    if (t) {
        set_url_with_tls(t->url);
    } else {
        ui_set_url(app.ui, "");
    }
}

// --- Actions (from key bindings) ---

static int get_count(void) {
    return app.mode.count > 0 ? app.mode.count : 1;
}

static void handle_action(const char *action, void *ctx) {
    (void)ctx;
    int count = get_count();

    // Focus overlay-aware scroll helper:
    // "var e=document.getElementById('swim-focus')||document.scrollingElement;"
    #define SCROLL_TARGET "var e=document.getElementById('swim-focus')||document.scrollingElement;"

    if (strcmp(action, "scroll-down") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollTop+=%d", 60 * count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-up") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollTop-=%d", 60 * count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-left") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollLeft-=%d", 60 * count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-right") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollLeft+=%d", 60 * count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-half-down") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollTop+=window.innerHeight/2*%d", count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-half-up") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollTop-=window.innerHeight/2*%d", count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-full-down") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollTop+=window.innerHeight*%d", count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-full-up") == 0) {
        char js[256];
        snprintf(js, sizeof(js), SCROLL_TARGET "e.scrollTop-=window.innerHeight*%d", count);
        ui_run_js(app.ui, js);
    } else if (strcmp(action, "scroll-top") == 0) {
        ui_run_js(app.ui, SCROLL_TARGET "e.scrollTop=0");
    } else if (strcmp(action, "scroll-bottom") == 0) {
        ui_run_js(app.ui, SCROLL_TARGET "e.scrollTop=e.scrollHeight");
    } else if (strcmp(action, "close-tab") == 0) {
        int idx = app.browser.active_tab;
        if (app.browser.tab_count <= 1) {
            ui_close(app.ui);
            return;
        }
        browser_close_tab(&app.browser, idx);
        ui_close_tab(app.ui, idx);
        // Sync browser active tab with UI
        browser_set_active(&app.browser, app.browser.active_tab);
        sync_tab_display();
    } else if (strcmp(action, "undo-close-tab") == 0) {
        if (app.browser.closed_count > 0) {
            char *url = app.browser.closed_urls[--app.browser.closed_count];
            create_tab(url);
            open_url_in_active_tab(url);
            free(url);
        }
    } else if (strcmp(action, "prev-tab") == 0) {
        int idx = app.browser.active_tab - 1;
        if (idx < 0) idx = app.browser.tab_count - 1;
        browser_set_active(&app.browser, idx);
        ui_select_tab(app.ui, idx);
        Tab *t = browser_active(&app.browser);
        if (t && t->lazy && t->url[0]) { t->lazy = false; ui_navigate(app.ui, t->url); }
        sync_tab_display();
    } else if (strcmp(action, "next-tab") == 0) {
        int idx = app.browser.active_tab + 1;
        if (idx >= app.browser.tab_count) idx = 0;
        browser_set_active(&app.browser, idx);
        ui_select_tab(app.ui, idx);
        Tab *t = browser_active(&app.browser);
        if (t && t->lazy && t->url[0]) { t->lazy = false; ui_navigate(app.ui, t->url); }
        sync_tab_display();
    } else if (strcmp(action, "goto-tab") == 0) {
        int target;
        if (app.mode.count > 0) {
            target = app.mode.count - 1;  // 1-indexed to 0-indexed
            if (target >= app.browser.tab_count) target = app.browser.tab_count - 1;
            if (target < 0) target = 0;
        } else {
            // No count = next tab (same as K)
            target = app.browser.active_tab + 1;
            if (target >= app.browser.tab_count) target = 0;
        }
        browser_set_active(&app.browser, target);
        ui_select_tab(app.ui, target);
        Tab *t = browser_active(&app.browser);
        if (t && t->lazy && t->url[0]) { t->lazy = false; ui_navigate(app.ui, t->url); }
        sync_tab_display();
    } else if (strcmp(action, "move-tab-left") == 0) {
        int idx = app.browser.active_tab;
        int target = idx - 1;
        if (target < 0) target = app.browser.tab_count - 1;
        browser_move_tab(&app.browser, idx, target);
        ui_move_tab(app.ui, idx, target);
        sync_tab_display();
    } else if (strcmp(action, "move-tab-right") == 0) {
        int idx = app.browser.active_tab;
        int target = idx + 1;
        if (target >= app.browser.tab_count) target = 0;
        browser_move_tab(&app.browser, idx, target);
        ui_move_tab(app.ui, idx, target);
        sync_tab_display();
    } else if (strcmp(action, "enter-command") == 0) {
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
        ui_show_command_bar(app.ui, NULL, NULL, NULL);
    } else if (strcmp(action, "command-open") == 0) {
        Tab *t = browser_active(&app.browser);
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
        ui_show_command_bar(app.ui, "open ", NULL, t ? t->url : NULL);
    } else if (strcmp(action, "command-open-current") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t) {
            mode_set(&app.mode, MODE_COMMAND);
            ui_set_mode(app.ui, MODE_COMMAND);
            ui_show_command_bar(app.ui, "open ", t->url, NULL);
        }
    } else if (strcmp(action, "command-tabopen") == 0) {
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
        ui_show_command_bar(app.ui, "tabopen ", NULL, NULL);
    } else if (strcmp(action, "reload") == 0) {
        ui_reload(app.ui);
    } else if (strcmp(action, "back") == 0) {
        ui_go_back(app.ui);
    } else if (strcmp(action, "forward") == 0) {
        ui_go_forward(app.ui);
    } else if (strcmp(action, "mode-normal") == 0) {
        ui_set_mode(app.ui, MODE_NORMAL);
        ui_hide_command_bar(app.ui);
        // Dismiss focus overlay if active, otherwise blur active element
        ui_run_js(app.ui,
            "var f=document.getElementById('swim-focus');"
            "if(f){f.remove();document.body.style.overflow='';}"
            "else{document.activeElement.blur()}");
    } else if (strcmp(action, "hint-follow") == 0) {
        mode_set(&app.mode, MODE_HINT);
        ui_set_mode(app.ui, MODE_HINT);
        ui_show_hints(app.ui, false);
    } else if (strcmp(action, "hint-tab") == 0) {
        mode_set(&app.mode, MODE_HINT);
        ui_set_mode(app.ui, MODE_HINT);
        ui_show_hints(app.ui, true);
    } else if (strcmp(action, "hint-filter") == 0) {
        ui_filter_hints(app.ui, app.mode.pending_keys);
    } else if (strcmp(action, "hint-cancel") == 0) {
        ui_cancel_hints(app.ui);
    } else if (strcmp(action, "find") == 0) {
        mode_set(&app.mode, MODE_COMMAND);
        ui_set_mode(app.ui, MODE_COMMAND);
        ui_show_find_bar(app.ui);
    } else if (strcmp(action, "find-next") == 0) {
        ui_find_next(app.ui);
    } else if (strcmp(action, "find-prev") == 0) {
        ui_find_prev(app.ui);
    } else if (strcmp(action, "yank-url") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t && t->url[0]) {
            NSString *url = [NSString stringWithUTF8String:t->url];
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:url forType:NSPasteboardTypeString];
            ui_set_status_message(app.ui, "Yanked URL");
        }
    } else if (strcmp(action, "yank-pretty-url") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t && t->url[0]) {
            NSString *encoded = [NSString stringWithUTF8String:t->url];
            NSString *decoded = [encoded stringByRemovingPercentEncoding];
            if (!decoded) decoded = encoded;
            [[NSPasteboard generalPasteboard] clearContents];
            [[NSPasteboard generalPasteboard] setString:decoded forType:NSPasteboardTypeString];
            ui_set_status_message(app.ui, "Yanked decoded URL");
        }
    } else if (strcmp(action, "paste-open") == 0) {
        NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        if (clip && clip.length > 0) {
            open_url_in_active_tab([clip UTF8String]);
        }
    } else if (strcmp(action, "paste-tabopen") == 0) {
        NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        if (clip && clip.length > 0) {
            create_tab(NULL);
            open_url_in_active_tab([clip UTF8String]);
        }
    } else if (strcmp(action, "command-tabopen-current") == 0) {
        Tab *t = browser_active(&app.browser);
        if (t) {
            mode_set(&app.mode, MODE_COMMAND);
            ui_set_mode(app.ui, MODE_COMMAND);
            ui_show_command_bar(app.ui, "tabopen ", t->url, NULL);
        }
    } else if (strcmp(action, "enter-passthrough") == 0) {
        mode_set(&app.mode, MODE_PASSTHROUGH);
        ui_set_mode(app.ui, MODE_PASSTHROUGH);
    }
}

// --- Commands (from command bar) ---

static void cmd_open(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0]) return;
    open_url_in_active_tab(args);
    Tab *t = browser_active(&app.browser);
    if (t) snprintf(t->url, sizeof(t->url), "%s", args);
}

static void cmd_tabopen(const char *args, void *ctx) {
    (void)ctx;
    if (args && args[0]) {
        create_tab(NULL);
        open_url_in_active_tab(args);
        Tab *t = browser_active(&app.browser);
        if (t) snprintf(t->url, sizeof(t->url), "%s", args);
    } else {
        create_tab(app.config.homepage);
    }
}

static void cmd_bookmark(const char *args, void *ctx) {
    (void)args; (void)ctx;
    Tab *t = browser_active(&app.browser);
    if (t && t->url[0]) {
        storage_add(&app.bookmarks, t->url, t->title);
        storage_save(&app.bookmarks);
    }
}

static void cmd_marks(const char *args, void *ctx) {
    (void)ctx;
    int results[20];
    int count = storage_search(&app.bookmarks, args ? args : "", results, 20);
    if (count > 0) {
        // Open the first match
        open_url_in_active_tab(app.bookmarks.entries[results[0]].url);
    }
}

static void cmd_history(const char *args, void *ctx) {
    (void)ctx;
    int results[20];
    int count = storage_search(&app.history, args ? args : "", results, 20);
    if (count > 0) {
        open_url_in_active_tab(app.history.entries[results[0]].url);
    }
}

static void cmd_set(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0]) return;

    // Split "key value"
    char key[64];
    int i = 0;
    while (args[i] && args[i] != ' ' && i < 63) {
        key[i] = args[i];
        i++;
    }
    key[i] = '\0';
    const char *value = args[i] ? args + i + 1 : "";

    config_set(&app.config, key, value);
}

static void cmd_adblock(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0] || strcmp(args, "on") == 0) {
        ui_set_adblock(app.ui, true);
    } else if (strcmp(args, "off") == 0) {
        ui_set_adblock(app.ui, false);
    }
}

static void cmd_passthrough(const char *args, void *ctx) {
    (void)args; (void)ctx;
    mode_set(&app.mode, MODE_PASSTHROUGH);
    ui_set_mode(app.ui, MODE_PASSTHROUGH);
}

static void cmd_focus(const char *args, void *ctx) {
    (void)args; (void)ctx;
    static const char *focus_js =
        "(function(){"

        // Toggle off
        "var overlay=document.getElementById('swim-focus');"
        "if(overlay){overlay.remove();document.body.style.overflow='';return;}"

        // Find main content — site-specific then generic
        "var article,isReddit=location.hostname==='old.reddit.com';"
        "var isRedditListing=false;"
        "if(isReddit){"
        "  article=document.querySelector('.sitetable.nestedlisting');"
        "  if(!article){article=document.querySelector('#siteTable');isRedditListing=!!article;}"
        "}else{"
        "  article=document.querySelector('article')"
        "  ||document.querySelector('[role=main]')"
        "  ||document.querySelector('.post-content,.entry-content,main');"
        "}"
        "if(!article){"
        "  var ps=document.querySelectorAll('p'),best=null,bestLen=0;"
        "  var cs=new Set();ps.forEach(function(p){cs.add(p.parentElement)});"
        "  cs.forEach(function(c){var l=c.textContent.length;if(l>bestLen){bestLen=l;best=c}});"
        "  article=best;"
        "}"
        "if(!article)return;"

        // Get title text, strip common site suffixes
        "var titleText=document.title||'';"
        "titleText=titleText.replace(/\\s*[-|\\u2013\\u2014]\\s*(Wikipedia|Reddit|reddit\\.com).*$/i,'');"
        "titleText=titleText.replace(/\\s*:\\s*(reddit\\.com)$/i,'');"
        "if(isReddit&&!isRedditListing){"
        "  var pt=document.querySelector('.top-matter .title a');"
        "  if(pt)titleText=pt.textContent;"
        "}"

        // Build overlay
        "var o=document.createElement('div');"
        "o.id='swim-focus';"
        "o.style.cssText='position:fixed;top:0;left:0;width:100%;height:100%;"
        "z-index:99999;background:#111;overflow-y:auto;';"

        // Inner content column
        "var inner=document.createElement('div');"
        "inner.style.cssText='max-width:700px;margin:60px auto 120px;padding:0 40px;';"

        // Title
        "var h=document.createElement('h1');"
        "h.textContent=titleText;"
        "h.style.cssText='font:bold 26px/1.3 system-ui,-apple-system,sans-serif;"
        "color:#e0e0e0;margin:0 0 8px;border:none;letter-spacing:-0.3px;';"
        "inner.appendChild(h);"

        // Reddit post body (self-text, images, galleries, video)
        "if(isReddit&&!isRedditListing){"
        // Fetch post JSON for gallery/media data, then build content
        "  (function loadRedditMedia(){"
        "    var jsonUrl=location.pathname.replace(/\\/$/,'')+ '.json';"
        "    fetch(jsonUrl).then(function(r){return r.json()}).then(function(data){"
        "      var post=data[0].data.children[0].data;"
        // Gallery: media_metadata has all images
        "      if(post.media_metadata){"
        "        var ids=post.gallery_data?post.gallery_data.items.map(function(i){return i.media_id})"
        "          :Object.keys(post.media_metadata);"
        "        ids.forEach(function(id){"
        "          var m=post.media_metadata[id];if(!m||m.status!=='valid')return;"
        "          var src=m.s?m.s.u||m.s.gif||'':'';"
        "          src=src.replace(/&amp;/g,'&');"
        "          if(!src)return;"
        "          var img=document.createElement('img');img.src=src;img.loading='lazy';"
        "          img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:0 0 16px;';"
        "          inner.insertBefore(img,inner.querySelector('#swim-focus-sep'));"
        "        });"
        "      }"
        // Single image post
        "      else if(post.url&&/\\.(jpg|jpeg|png|gif|webp)(\\?.*)?$/i.test(post.url)){"
        "        var img=document.createElement('img');img.src=post.url;"
        "        img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:0 0 16px;';"
        "        inner.insertBefore(img,inner.querySelector('#swim-focus-sep'));"
        "      }"
        // Preview image (for link posts with thumbnails)
        "      else if(post.preview&&post.preview.images&&post.preview.images[0]){"
        "        var src=post.preview.images[0].source.url.replace(/&amp;/g,'&');"
        "        var img=document.createElement('img');img.src=src;"
        "        img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:0 0 16px;';"
        "        inner.insertBefore(img,inner.querySelector('#swim-focus-sep'));"
        "      }"
        // Video (v.redd.it)
        "      if(post.secure_media&&post.secure_media.reddit_video){"
        "        var v=document.createElement('video');v.controls=true;"
        "        v.src=post.secure_media.reddit_video.fallback_url;"
        "        v.style.cssText='max-width:100%;border-radius:4px;margin:0 0 16px;';"
        "        inner.insertBefore(v,inner.querySelector('#swim-focus-sep'));"
        "      }"
        "    }).catch(function(){});"
        "  })();"
        // Self-text body (available immediately, no fetch needed)
        "  var selfText=document.querySelector('.expando .usertext-body');"
        "  if(selfText&&selfText.textContent.trim()){"
        "    var pb=selfText.cloneNode(true);"
        "    pb.style.cssText='font:15px/1.7 Georgia,serif;color:#d0ccc4;margin:0 0 8px;';"
        "    inner.appendChild(pb);"
        "  }"
        "}"

        // Separator
        "var hr=document.createElement('div');"
        "hr.id='swim-focus-sep';"
        "hr.style.cssText='width:60px;height:1px;background:#333;margin:16px 0 32px;';"
        "inner.appendChild(hr);"

        // Extract content — reddit-specific
        "if(isReddit&&isRedditListing){"
        // Listing page: render each post as a clean card
        "  var things=article.querySelectorAll('.thing.link');"
        "  things.forEach(function(t){"
        "    var titleEl=t.querySelector('.title a.title');"
        "    if(!titleEl)return;"
        "    var author=t.querySelector('.author');"
        "    var score=t.querySelector('.score.unvoted');"
        "    var comments=t.querySelector('.comments');"
        "    var domain=t.querySelector('.domain a');"
        "    var selfText=t.querySelector('.expando .usertext-body');"
        "    var thumb=t.querySelector('.thumbnail img');"

        "    var row=document.createElement('div');"
        "    row.style.cssText='padding:16px 0;border-bottom:1px solid #1a1a1a;';"

        // Post title as link
        "    var h=document.createElement('a');"
        "    h.href=titleEl.href;"
        "    h.textContent=titleEl.textContent;"
        "    h.style.cssText='font:bold 16px/1.4 system-ui,sans-serif;color:#6eb5ff;"
        "    text-decoration:none;display:block;margin:0 0 6px;';"
        "    row.appendChild(h);"

        // Thumbnail if available
        "    if(thumb&&thumb.src&&!thumb.src.includes('self')&&!thumb.src.includes('nsfw')){"
        "      var img=document.createElement('img');img.src=thumb.src;img.loading='lazy';"
        "      img.style.cssText='max-width:100%;max-height:300px;border-radius:4px;margin:0 0 8px;display:block;';"
        "      row.appendChild(img);"
        "    }"

        // Self-text preview
        "    if(selfText&&selfText.textContent.trim()){"
        "      var preview=document.createElement('div');"
        "      preview.innerHTML=selfText.innerHTML;"
        "      preview.style.cssText='font:14px/1.6 Georgia,serif;color:#999;margin:0 0 8px;"
        "      max-height:120px;overflow:hidden;';"
        "      row.appendChild(preview);"
        "    }"

        // Meta line: score, author, comments, domain
        "    var meta=document.createElement('div');"
        "    meta.style.cssText='font:12px/1 system-ui,sans-serif;color:#555;';"
        "    var parts=[];"
        "    if(score)parts.push(score.textContent);"
        "    if(author)parts.push(author.textContent);"
        "    if(comments)parts.push(comments.textContent);"
        "    if(domain)parts.push(domain.textContent);"
        "    meta.textContent=parts.join(' \\u00B7 ');"
        "    row.appendChild(meta);"

        "    inner.appendChild(row);"
        "  });"
        "}else if(isReddit){"
        // Comments page: build clean comment tree
        "  var comments=article.querySelectorAll('.comment');"
        "  comments.forEach(function(c){"
        "    var entry=c.querySelector('.entry');"
        "    if(!entry)return;"
        "    var author=c.querySelector('.author');"
        "    var body=c.querySelector('.usertext-body');"
        "    var score=c.querySelector('.score.unvoted');"
        "    if(!body||!body.textContent.trim())return;"
        "    var depth=0;var p=c;while(p=p.parentElement){"
        "      if(p.classList&&p.classList.contains('comment'))depth++;"
        "    }"

        "    var row=document.createElement('div');"
        "    row.style.cssText='margin:0 0 4px;padding:12px 0 12px '+(depth*24)+'px;"
        "    border-bottom:1px solid #1a1a1a;';"

        "    var meta=document.createElement('div');"
        "    meta.style.cssText='font:12px/1 system-ui,sans-serif;color:#555;margin:0 0 6px;';"
        "    meta.textContent=(author?author.textContent:'[deleted]')"
        "      +(score?' \\u00B7 '+score.textContent:'');"
        "    row.appendChild(meta);"

        "    var text=document.createElement('div');"
        "    text.innerHTML=body.innerHTML;"
        "    text.style.cssText='font:15px/1.7 Georgia,serif;color:#d0ccc4;';"
        // Embed images from links in comments
        "    text.querySelectorAll('a').forEach(function(a){"
        "      var u=a.href||'';"
        "      if(/\\.(jpg|jpeg|png|gif|webp)(\\?.*)?$/i.test(u)"
        "        ||/i\\.redd\\.it|preview\\.redd\\.it|i\\.imgur\\.com/i.test(u)){"
        "        var img=document.createElement('img');"
        "        img.src=u;img.loading='lazy';"
        "        img.style.cssText='max-width:100%;height:auto;border-radius:4px;margin:8px 0;display:block;';"
        "        a.parentNode.insertBefore(img,a.nextSibling);"
        "      }"
        "    });"
        "    row.appendChild(text);"

        "    inner.appendChild(row);"
        "  });"
        "}else{"

        // Generic: clone and strip
        "  var clone=article.cloneNode(true);"
        "  clone.querySelectorAll('nav,header,footer,.sidebar,.ad,.social-share,"
        ".related-posts,.newsletter,aside,[role=complementary],"
        "script,style,iframe,.share,.hidden').forEach(function(e){e.remove()});"
        "  inner.appendChild(clone);"
        "}"

        // Styles
        "var s=document.createElement('style');"
        "s.textContent='"
        "#swim-focus *{box-sizing:border-box}"
        "#swim-focus p{margin:0 0 1.2em;line-height:1.7}"
        "#swim-focus img{max-width:100%;height:auto;border-radius:4px;margin:1em auto;display:block}"
        "#swim-focus a{color:#6eb5ff;text-decoration:none}"
        "#swim-focus a:hover{text-decoration:underline}"
        "#swim-focus pre{background:#1a1a1a;padding:16px;border-radius:6px;"
        "overflow-x:auto;font:14px/1.5 ui-monospace,monospace;color:#aaa}"
        "#swim-focus code{font:14px ui-monospace,monospace;color:#aaa;"
        "background:#1a1a1a;padding:2px 5px;border-radius:3px}"
        "#swim-focus pre code{padding:0;background:none}"
        "#swim-focus h1,#swim-focus h2,#swim-focus h3,#swim-focus h4{"
        "font-family:system-ui,sans-serif;color:#e0e0e0;margin:1.5em 0 0.5em;line-height:1.3}"
        "#swim-focus h2{font-size:22px}#swim-focus h3{font-size:18px}"
        "#swim-focus blockquote{border-left:3px solid #333;margin:1em 0;padding:0 0 0 20px;color:#888}"
        "#swim-focus ul,#swim-focus ol{padding-left:24px}"
        "#swim-focus li{margin:0.3em 0;color:#d0ccc4}"
        "#swim-focus table{border-collapse:collapse;width:100%;margin:1em 0}"
        "#swim-focus td,#swim-focus th{border:1px solid #222;padding:8px;text-align:left;color:#aaa}"
        "#swim-focus th{background:#1a1a1a;color:#ccc}"
        "#swim-focus hr{border:none;border-top:1px solid #222;margin:2em 0}"
        "#swim-focus .md{font:15px/1.7 Georgia,serif;color:#d0ccc4}"
        "';"
        "o.appendChild(s);"

        "o.appendChild(inner);"
        "document.body.appendChild(o);"
        "document.body.style.overflow='hidden';"
        "o.scrollTop=0;"
        "o.focus();"
        "})()";
    ui_run_js(app.ui, focus_js);
}

static void cmd_session(const char *args, void *ctx) {
    (void)ctx;
    if (!args || !args[0]) return;

    const char *home = getenv("HOME");
    if (!home) return;

    // Parse "save name" or "load name"
    char subcmd[32] = "";
    char name[128] = "";
    int i = 0;
    while (args[i] && args[i] != ' ' && i < 31) { subcmd[i] = args[i]; i++; }
    subcmd[i] = '\0';
    if (args[i] == ' ') {
        i++;
        int j = 0;
        while (args[i] && j < 127) { name[j++] = args[i++]; }
        name[j] = '\0';
    }

    if (!name[0]) {
        ui_set_status_message(app.ui, "Usage: session save|load <name>");
        return;
    }

    // Reject unsafe session names
    for (int k = 0; name[k]; k++) {
        char c = name[k];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_')) {
            ui_set_status_message(app.ui, "Session name: alphanumeric, - and _ only");
            return;
        }
    }

    char path[512];
    snprintf(path, sizeof(path), "%s/.config/swim/session-%s.json", home, name);

    if (strcmp(subcmd, "save") == 0) {
        const char *urls[128];
        int count = 0;
        for (int k = 0; k < app.browser.tab_count && count < 128; k++) {
            if (app.browser.tabs[k].url[0])
                urls[count++] = app.browser.tabs[k].url;
        }
        session_save(path, urls, count);
        char msg[256];
        snprintf(msg, sizeof(msg), "Session '%s' saved (%d tabs)", name, count);
        ui_set_status_message(app.ui, msg);
    } else if (strcmp(subcmd, "load") == 0) {
        char session_urls[128][2048];
        int session_count = session_load(path, session_urls, 128);
        if (session_count > 0) {
            for (int k = 0; k < session_count; k++) {
                create_tab(session_urls[k]);
            }
            char msg[256];
            snprintf(msg, sizeof(msg), "Session '%s' loaded (%d tabs)", name, session_count);
            ui_set_status_message(app.ui, msg);
        } else {
            char msg[256];
            snprintf(msg, sizeof(msg), "Session '%s' not found", name);
            ui_set_status_message(app.ui, msg);
        }
    }
}

static void cmd_tabs(const char *args, void *ctx) {
    (void)args; (void)ctx;
    if (app.browser.tab_count == 0) return;

    char buf[2048] = {0};
    int pos = 0;
    for (int i = 0; i < app.browser.tab_count && pos < (int)sizeof(buf) - 100; i++) {
        Tab *t = &app.browser.tabs[i];
        const char *title = t->title[0] ? t->title : t->url;
        char short_title[30];
        snprintf(short_title, sizeof(short_title), "%s", title);

        if (i > 0) pos += snprintf(buf + pos, sizeof(buf) - pos, " | ");
        if (i == app.browser.active_tab) {
            pos += snprintf(buf + pos, sizeof(buf) - pos, "%d: *%s", i + 1, short_title);
        } else {
            pos += snprintf(buf + pos, sizeof(buf) - pos, "%d: %s", i + 1, short_title);
        }
    }
    ui_set_status_message(app.ui, buf);
}

static void cmd_tabclose(const char *args, void *ctx) {
    (void)ctx;
    int target;
    if (args && args[0]) {
        target = atoi(args) - 1;
    } else {
        target = app.browser.active_tab;
    }

    if (target < 0 || target >= app.browser.tab_count) {
        ui_set_status_message(app.ui, "Invalid tab number");
        return;
    }

    if (app.browser.tab_count <= 1) {
        ui_close(app.ui);
        return;
    }

    browser_close_tab(&app.browser, target);
    ui_close_tab(app.ui, target);
    browser_set_active(&app.browser, app.browser.active_tab);
    sync_tab_display();
}

static void cmd_tabonly(const char *args, void *ctx) {
    (void)args; (void)ctx;
    int keep = app.browser.active_tab;

    for (int i = app.browser.tab_count - 1; i >= 0; i--) {
        if (i == keep) continue;
        browser_close_tab(&app.browser, i);
        ui_close_tab(app.ui, i);
        if (i < keep) keep--;
    }
    browser_set_active(&app.browser, 0);
    sync_tab_display();
}

static void cmd_quit(const char *args, void *ctx) {
    (void)args; (void)ctx;
    ui_close(app.ui);
}

// --- UI Callbacks ---

static void substitute_vars(const char *input, char *output, int output_size) {
    int oi = 0;
    int remaining;

    // Safe append via snprintf — clamp oi to prevent overflow
    #define SUBST_APPEND(fmt, val) do { \
        remaining = output_size - oi; \
        if (remaining > 1) { \
            int n = snprintf(&output[oi], remaining, fmt, val); \
            oi += (n < remaining) ? n : (remaining - 1); \
        } \
    } while(0)

    for (int i = 0; input[i] && oi < output_size - 1; i++) {
        if (input[i] == '{') {
            if (strncmp(&input[i], "{url}", 5) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) SUBST_APPEND("%s", t->url);
                i += 4; continue;
            } else if (strncmp(&input[i], "{title}", 7) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) SUBST_APPEND("%s", t->title);
                i += 6; continue;
            } else if (strncmp(&input[i], "{clipboard}", 11) == 0) {
                NSString *clip = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
                if (clip) SUBST_APPEND("%s", [clip UTF8String]);
                i += 10; continue;
            } else if (strncmp(&input[i], "{url:host}", 10) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) {
                    NSString *s = [NSString stringWithUTF8String:t->url];
                    NSURL *u = [NSURL URLWithString:s];
                    if (u.host) SUBST_APPEND("%s", [u.host UTF8String]);
                }
                i += 9; continue;
            } else if (strncmp(&input[i], "{url:path}", 10) == 0) {
                Tab *t = browser_active(&app.browser);
                if (t) {
                    NSString *s = [NSString stringWithUTF8String:t->url];
                    NSURL *u = [NSURL URLWithString:s];
                    if (u.path) SUBST_APPEND("%s", [u.path UTF8String]);
                }
                i += 9; continue;
            }
        }
        output[oi++] = input[i];
    }
    output[oi] = '\0';

    #undef SUBST_APPEND
}

static void on_command_submit(const char *text, void *ctx) {
    (void)ctx;
    mode_set(&app.mode, MODE_NORMAL);
    ui_set_mode(app.ui, MODE_NORMAL);
    ui_hide_command_bar(app.ui);

    // Variable substitution
    char expanded[4096];
    substitute_vars(text, expanded, sizeof(expanded));

    if (!registry_exec(&app.commands, expanded)) {
        char msg[256];
        snprintf(msg, sizeof(msg), "Unknown command: %s", expanded);
        ui_set_status_message(app.ui, msg);
    }
}

static void on_command_cancel(void *ctx) {
    (void)ctx;
    mode_set(&app.mode, MODE_NORMAL);
    ui_set_mode(app.ui, MODE_NORMAL);
    ui_hide_command_bar(app.ui);
}

static void on_url_changed(const char *url, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_url(&app.browser, tab_id, url);
    Tab *t = browser_active(&app.browser);
    if (t && t->id == tab_id) {
        set_url_with_tls(url);
    }
    // Record in history
    if (url && strncmp(url, "about:", 6) != 0) {
        int idx = browser_find_tab(&app.browser, tab_id);
        const char *title = (idx >= 0) ? app.browser.tabs[idx].title : "";
        storage_add(&app.history, url, title);
        storage_save(&app.history);
    }
}

static void on_title_changed(const char *title, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_title(&app.browser, tab_id, title);
    ui_update_tab_title(app.ui, tab_id, title);

    // Update window title to active tab
    Tab *t = browser_active(&app.browser);
    if (t && t->id == tab_id) {
        ui_set_window_title(app.ui, t->title);
    }
}

static void on_load_changed(bool loading, double progress, int tab_id, void *ctx) {
    (void)ctx;
    browser_tab_set_loading(&app.browser, tab_id, loading, progress);
    ui_set_progress(app.ui, progress);
}

static void on_focus_changed(bool focused, void *ctx) {
    (void)ctx;
    if (focused) {
        mode_set(&app.mode, MODE_INSERT);
        ui_set_mode(app.ui, MODE_INSERT);
    } else {
        mode_set(&app.mode, MODE_NORMAL);
        ui_set_mode(app.ui, MODE_NORMAL);
    }
}

static void on_hints_done(void *ctx) {
    (void)ctx;
    mode_set(&app.mode, MODE_NORMAL);
    ui_set_mode(app.ui, MODE_NORMAL);
}

static const char *on_command_complete(const char *prefix, void *ctx) {
    (void)ctx;
    return registry_complete(&app.commands, prefix);
}

static void on_tab_selected(int index, void *ctx) {
    (void)ctx;
    browser_set_active(&app.browser, index);
    ui_select_tab(app.ui, index);

    // Lazy tab loading: navigate on first select
    Tab *t = browser_active(&app.browser);
    if (t && t->lazy && t->url[0]) {
        t->lazy = false;
        ui_navigate(app.ui, t->url);
    }

    sync_tab_display();
}

// --- Main ---

int main(int argc, const char *argv[]) {

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

#ifdef SWIM_TEST
        int test_port = 0;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--test-server") == 0 && i + 1 < argc) {
                test_port = atoi(argv[++i]);
            }
        }
#endif

        // Ensure config dir exists
        storage_ensure_dir();

        // Load config
        config_init(&app.config);
        const char *home = getenv("HOME");
        snprintf(app.config_path, sizeof(app.config_path),
            "%s/.config/swim/config.toml", home ? home : ".");
        config_load(&app.config, app.config_path);

        // Init storage
        char bm_path[512], hist_path[512];
        snprintf(bm_path, sizeof(bm_path), "%s/.config/swim/bookmarks.json", home ? home : ".");
        snprintf(hist_path, sizeof(hist_path), "%s/.config/swim/history.json", home ? home : ".");
        storage_init(&app.bookmarks, bm_path);
        storage_init(&app.history, hist_path);
        storage_load(&app.bookmarks);
        storage_load(&app.history);
        snprintf(app.session_path, sizeof(app.session_path),
            "%s/.config/swim/session.json", home ? home : ".");

        // Init pure C state
        browser_init(&app.browser);
        mode_init(&app.mode, handle_action, &app);

        // Apply custom keybindings from config
        for (int i = 0; i < app.config.key_binding_count; i++) {
            keytrie_bind(&app.mode.normal_keys,
                app.config.key_bindings[i].keys,
                app.config.key_bindings[i].action);
        }

        registry_init(&app.commands, &app);
        registry_add(&app.commands, "open", "o", cmd_open, "Navigate to URL");
        registry_add(&app.commands, "tabopen", "to", cmd_tabopen, "Open in new tab");
        registry_add(&app.commands, "quit", "q", cmd_quit, "Quit swim");
        registry_add(&app.commands, "adblock", NULL, cmd_adblock, "Toggle adblock on/off");
        registry_add(&app.commands, "bookmark", "bm", cmd_bookmark, "Bookmark current page");
        registry_add(&app.commands, "marks", NULL, cmd_marks, "Search bookmarks");
        registry_add(&app.commands, "history", NULL, cmd_history, "Search history");
        registry_add(&app.commands, "set", NULL, cmd_set, "Set config value");
        registry_add(&app.commands, "passthrough", NULL, cmd_passthrough, "Enter passthrough mode");
        registry_add(&app.commands, "focus", NULL, cmd_focus, "Reader mode");
        registry_add(&app.commands, "session", NULL, cmd_session, "Save/load named sessions");
        registry_add(&app.commands, "tabs", NULL, cmd_tabs, "List open tabs");
        registry_add(&app.commands, "tabclose", "tc", cmd_tabclose, "Close tab by number");
        registry_add(&app.commands, "tabonly", NULL, cmd_tabonly, "Close all tabs except current");

        // Create UI
        UICallbacks callbacks = {
            .on_command_submit = on_command_submit,
            .on_command_cancel = on_command_cancel,
            .on_url_changed = on_url_changed,
            .on_title_changed = on_title_changed,
            .on_load_changed = on_load_changed,
            .on_focus_changed = on_focus_changed,
            .on_hints_done = on_hints_done,
            .on_tab_selected = on_tab_selected,
            .on_command_complete = on_command_complete,
            .ctx = &app,
        };
        app.ui = ui_create(callbacks, app.config.compact_titlebar);

        // Load adblock rules
        if (app.config.adblock_enabled) {
            ui_load_blocklist(app.ui);
        }

        // Open URLs from command line, restore session, or open homepage
        {
            int opened = 0;
            // CLI arguments: ./swim url1 url2 ...
            for (int i = 1; i < argc; i++) {
                if (argv[i][0] == '-') {
#ifdef SWIM_TEST
                    if (strcmp(argv[i], "--test-server") == 0 && i + 1 < argc) i++;  // skip port arg
#endif
                    continue;
                }
                create_tab(argv[i]);
                opened++;
            }
            if (!opened && app.config.restore_session) {
                char session_urls[128][2048];
                int session_count = session_load(app.session_path, session_urls, 128);
                if (session_count > 0) {
                    create_tab(session_urls[0]);
                    for (int i = 1; i < session_count; i++) {
                        int tab_id = browser_add_tab(&app.browser, session_urls[i]);
                        int idx = browser_find_tab(&app.browser, tab_id);
                        if (idx >= 0) app.browser.tabs[idx].lazy = true;
                        ui_add_tab(app.ui, NULL, tab_id);
                        ui_update_tab_title(app.ui, tab_id, session_urls[i]);
                    }
                    browser_set_active(&app.browser, 0);
                    ui_select_tab(app.ui, 0);
                    sync_tab_display();
                    opened = 1;
                }
            }
            if (!opened) {
                create_tab(app.config.homepage);
            }
        }

#ifdef SWIM_TEST
        if (test_port > 0) {
            // Fixed window size for consistent screenshots
            NSWindow *test_window = (__bridge NSWindow *)ui_get_window(app.ui);
            [test_window setFrame:NSMakeRect(100, 100, 1280, 800) display:YES animate:NO];

            static TestContext test_ctx;
            test_ctx = (TestContext){
                .ui = app.ui,
                .browser = &app.browser,
                .mode = &app.mode,
                .commands = &app.commands,
                .handle_action = handle_action,
                .action_ctx = &app,
            };
            // test_ctx is static — safe for the server thread to reference
            test_server_start(test_port, &test_ctx);
        }
#endif

        // Key event monitor
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                // Don't intercept when command bar is focused
                if (app.mode.mode == MODE_COMMAND && !([event.characters isEqualToString:@"\x1b"])) {
                    return event;
                }

                const char *chars = [event.characters UTF8String];
                if (!chars || !chars[0]) return event;

                unsigned int mods = 0;
                NSEventModifierFlags flags = event.modifierFlags;
                if (flags & NSEventModifierFlagControl) mods |= MOD_CTRL;
                if (flags & NSEventModifierFlagShift)   mods |= MOD_SHIFT;
                if (flags & NSEventModifierFlagOption)   mods |= MOD_ALT;
                if (flags & NSEventModifierFlagCommand)  mods |= MOD_CMD;

                // Handle Cmd shortcuts we own, pass the rest through
                if (mods & MOD_CMD) {
                    const char *unmod = [event.charactersIgnoringModifiers UTF8String];
                    if (unmod) {
                        if (unmod[0] == '=' || unmod[0] == '+') {
                            ui_zoom_in(app.ui); return nil;
                        }
                        if (unmod[0] == '-') {
                            ui_zoom_out(app.ui); return nil;
                        }
                        if (unmod[0] == '0') {
                            ui_zoom_reset(app.ui); return nil;
                        }
                        if (unmod[0] == 'l') {
                            handle_action("command-open-current", &app); return nil;
                        }
                    }
                    return event;
                }

                bool consumed = mode_handle_key(&app.mode, chars, mods);
                // Show count prefix + pending keys in status bar
                char pending_display[64] = "";
                if (app.mode.count > 0)
                    snprintf(pending_display, sizeof(pending_display), "%d%s",
                        app.mode.count, app.mode.pending_keys);
                else
                    snprintf(pending_display, sizeof(pending_display), "%s",
                        app.mode.pending_keys);
                ui_set_pending_keys(app.ui, pending_display);
                return consumed ? nil : event;
            }];

        // Activate and run
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];

        // Save session
        {
            const char *urls[128];
            int count = 0;
            for (int i = 0; i < app.browser.tab_count && count < 128; i++) {
                if (app.browser.tabs[i].url[0]) {
                    urls[count++] = app.browser.tabs[i].url;
                }
            }
            session_save(app.session_path, urls, count);
        }

        // Cleanup
        storage_save(&app.history);
        storage_save(&app.bookmarks);
        storage_free(&app.history);
        storage_free(&app.bookmarks);
        mode_free(&app.mode);
        registry_free(&app.commands);
        browser_free(&app.browser);
    }

    return 0;
}
