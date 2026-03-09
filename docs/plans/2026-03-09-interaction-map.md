# Interaction Map & Form Filling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give AI agents a structured view of interactable page elements (forms, buttons, selects, checkboxes) and the ability to fill/submit forms — enabling LOB automation and collaborative browsing.

**Architecture:** New `js/interact.js` discovers interactable elements and returns a structured JSON map. New `/interact` GET endpoint injects it. New `/fill` POST endpoint sets form values by selector. New `/wait_for` POST endpoint polls for a CSS selector to appear. All three get wired into the MCP `swim` meta-tool as new methods and into `/batch`.

**Tech Stack:** JavaScript (DOM inspection), Objective-C (serve.m endpoints), C (swim-mcp.c methods)

**Design doc:** `docs/plans/2026-03-09-ai-native-platform-design.md`

---

### Task 1: Create js/interact.js — interaction map script

Discovers all interactable elements on the page and returns structured JSON. This is the core intelligence — it needs to find form fields, buttons, links, selects, textareas, checkboxes, radios, and report their current state.

**Files:**
- Create: `js/interact.js`

**Step 1: Write the interaction map script**

```javascript
(function(){
  var elements = [];
  var idx = 0;

  // Helper: generate a unique CSS selector for an element
  function getSelector(el) {
    if (el.id) return '#' + CSS.escape(el.id);
    if (el.name && el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA') {
      var byName = document.querySelectorAll(el.tagName + '[name="' + el.name + '"]');
      if (byName.length === 1) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
    }
    // Fallback: nth-of-type path
    var path = [];
    var node = el;
    while (node && node !== document.body && node !== document.documentElement) {
      var parent = node.parentElement;
      if (!parent) break;
      var siblings = parent.querySelectorAll(':scope > ' + node.tagName);
      if (siblings.length === 1) {
        path.unshift(node.tagName.toLowerCase());
      } else {
        var index = Array.prototype.indexOf.call(siblings, node) + 1;
        path.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
      }
      node = parent;
    }
    return path.join(' > ');
  }

  // Helper: is element visible?
  function isVisible(el) {
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var style = getComputedStyle(el);
    return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
  }

  // Helper: get label text for a form element
  function getLabel(el) {
    // Explicit label via for attribute
    if (el.id) {
      var label = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
      if (label) return label.textContent.trim();
    }
    // Wrapped in label
    var parent = el.closest('label');
    if (parent) return parent.textContent.trim().substring(0, 100);
    // aria-label
    if (el.getAttribute('aria-label')) return el.getAttribute('aria-label');
    // placeholder
    if (el.placeholder) return el.placeholder;
    return '';
  }

  // Collect inputs, textareas, selects
  var formEls = document.querySelectorAll('input, textarea, select');
  for (var i = 0; i < formEls.length && elements.length < 200; i++) {
    var el = formEls[i];
    if (!isVisible(el)) continue;
    if (el.type === 'hidden') continue;

    var info = {
      idx: idx++,
      tag: el.tagName.toLowerCase(),
      type: el.type || '',
      name: el.name || '',
      selector: getSelector(el),
      label: getLabel(el),
      enabled: !el.disabled,
      required: el.required || false
    };

    if (el.tagName === 'SELECT') {
      info.options = [];
      for (var j = 0; j < el.options.length && j < 50; j++) {
        info.options.push({
          value: el.options[j].value,
          text: el.options[j].text.trim(),
          selected: el.options[j].selected
        });
      }
      info.value = el.value;
    } else if (el.type === 'checkbox' || el.type === 'radio') {
      info.checked = el.checked;
      info.value = el.value;
    } else {
      info.value = el.value || '';
    }

    elements.push(info);
  }

  // Collect buttons (button elements + input[type=submit/button/reset] + [role=button])
  var buttons = document.querySelectorAll('button, input[type="submit"], input[type="button"], input[type="reset"], [role="button"]');
  for (var i = 0; i < buttons.length && elements.length < 300; i++) {
    var el = buttons[i];
    if (!isVisible(el)) continue;
    // Skip if already collected as form element
    if (el.tagName === 'INPUT' && (el.type === 'submit' || el.type === 'button' || el.type === 'reset')) {
      var already = false;
      for (var j = 0; j < elements.length; j++) {
        if (elements[j].selector === getSelector(el)) { already = true; break; }
      }
      if (already) continue;
    }

    elements.push({
      idx: idx++,
      tag: 'button',
      type: el.type || 'button',
      selector: getSelector(el),
      text: (el.textContent || el.value || '').trim().substring(0, 100),
      enabled: !el.disabled
    });
  }

  // Group form elements by their parent <form>
  var forms = [];
  var formMap = {};
  for (var i = 0; i < elements.length; i++) {
    var el = document.querySelector(elements[i].selector);
    if (!el) continue;
    var form = el.closest('form');
    if (form) {
      var formId = form.id || form.action || ('form-' + forms.length);
      if (!formMap[formId]) {
        formMap[formId] = {
          id: form.id || '',
          action: form.action || '',
          method: (form.method || 'get').toUpperCase(),
          selector: getSelector(form),
          fields: []
        };
        forms.push(formMap[formId]);
      }
      formMap[formId].fields.push(elements[i]);
    }
  }

  return JSON.stringify({
    url: location.href,
    title: document.title,
    elements: elements,
    forms: forms,
    element_count: elements.length,
    form_count: forms.length
  });
})();
```

**Step 2: Verify syntax**

Open the file and visually confirm no syntax errors. The script is an IIFE that returns a JSON string.

**Step 3: Commit**

```bash
git add js/interact.js
git commit -m "Add interact.js for structured interactable element discovery"
```

---

### Task 2: Wire /interact endpoint into serve.m

Add the endpoint following the exact same pattern as `/extract`: embed JS via .inc file, inject into webview, parse returned JSON string.

**Files:**
- Create: `interact_js.inc` (generated)
- Modify: `Makefile` — add interact_js.inc rule and dependency
- Modify: `serve.m` — add kInteractJS, do_interact, handle_interact, route, batch type

**Step 1: Update Makefile**

Add the interact_js.inc generation rule (after extract_js.inc rule):

```makefile
interact_js.inc: js/interact.js
	@echo "Generating interact_js.inc"
	@sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$$/\\n"/' js/interact.js > interact_js.inc
```

Update swim dependency line:

```makefile
swim: $(SRC) $(HEADERS) focus_js.inc extract_js.inc interact_js.inc Info.plist
```

Update clean:

```makefile
clean:
	rm -f swim swim-mcp focus_js.inc extract_js.inc interact_js.inc
```

**Step 2: Add to .gitignore**

Add `interact_js.inc` to `.gitignore` (it's a generated file like extract_js.inc).

**Step 3: Add kInteractJS to serve.m**

After the existing `kExtractJS` declaration (line 11-13), add:

```c
static const char *kInteractJS =
#include "interact_js.inc"
;
```

**Step 4: Add do_interact to serve.m**

After `do_extract` (line 394), add `do_interact` — identical pattern to `do_extract` but uses `kInteractJS`:

```c
static NSDictionary *do_interact(ServeContext *ctx) {
    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

        __block NSDictionary *response = nil;
        __block BOOL done = NO;

        NSString *js = [NSString stringWithUTF8String:kInteractJS];
        [wv evaluateJavaScript:js completionHandler:^(id res, NSError *error) {
            if (error) {
                response = @{@"ok": @NO, @"error": error.localizedDescription ?: @"unknown"};
            } else if (res && [res isKindOfClass:[NSString class]]) {
                NSData *data = [(NSString *)res dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (parsed) {
                    NSMutableDictionary *r = [parsed mutableCopy];
                    r[@"ok"] = @YES;
                    response = r;
                } else {
                    response = @{@"ok": @NO, @"error": @"parse failed"};
                }
            } else {
                response = @{@"ok": @NO, @"error": @"no result"};
            }
            done = YES;
        }];

        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:timeout]) {
            if ([timeout timeIntervalSinceNow] <= 0) break;
        }

        if (!done) result = @{@"ok": @NO, @"error": @"interact timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"interact failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"interact failed"};
}
```

**Step 5: Add handle_interact and route**

After `handle_extract`:

```c
static void handle_interact(int fd, ServeContext *ctx) {
    send_dict(fd, do_interact(ctx));
}
```

Add route in server_thread, after the `/extract` route:

```c
} else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/interact") == 0) {
    handle_interact(client_fd, ctx);
}
```

**Step 6: Add to batch handler**

In the batch type dispatch chain, after the `"extract"` case:

```c
} else if ([type isEqualToString:@"interact"]) {
    result = do_interact(ctx);
}
```

**Step 7: Build and smoke test**

```bash
make clean && make
# Terminal 1: ./swim --serve 9111 https://duckduckgo.com
# Terminal 2:
curl -s http://localhost:9111/interact | python3 -m json.tool
```

Expected: JSON with `elements` array containing the search input, buttons, etc. `forms` array with the search form grouped.

**Step 8: Commit**

```bash
git add Makefile serve.m .gitignore
git commit -m "Add /interact endpoint for structured element discovery"
```

---

### Task 3: Add /fill endpoint to serve.m

Sets form field values by CSS selector. Supports text inputs, selects, checkboxes, radios, and textareas. Takes an array of `{selector, value}` pairs so multiple fields can be filled in one call.

**Files:**
- Modify: `serve.m` — add do_fill, handle_fill, route, batch type

**Step 1: Add do_fill to serve.m**

After `do_interact`, add:

```c
static NSDictionary *do_fill(NSDictionary *json, ServeContext *ctx) {
    NSArray *fields = json[@"fields"];
    if (!fields || ![fields isKindOfClass:[NSArray class]] || fields.count == 0) {
        // Single-field shorthand: {selector, value}
        NSString *selector = json[@"selector"];
        NSString *value = json[@"value"];
        if (!selector) return @{@"ok": @NO, @"error": @"missing selector or fields array"};
        fields = @[@{@"selector": selector, @"value": value ?: @""}];
    }

    // Build JS that fills all fields
    NSMutableString *js = [NSMutableString stringWithString:@"(function(){var results=[];"];

    for (NSDictionary *field in fields) {
        NSString *sel = field[@"selector"];
        if (!sel) continue;

        NSString *escapedSel = [sel stringByReplacingOccurrencesOfString:@"'"
                                                             withString:@"\\'"];
        NSString *value = [field[@"value"] description] ?: @"";
        NSString *escapedVal = [value stringByReplacingOccurrencesOfString:@"'"
                                                               withString:@"\\'"];
        escapedVal = [escapedVal stringByReplacingOccurrencesOfString:@"\n"
                                                          withString:@"\\n"];

        [js appendFormat:
            @"var el=document.querySelector('%@');"
            "if(!el){results.push({selector:'%@',ok:false,error:'not found'})}"
            "else if(el.tagName==='SELECT'){"
            "  el.value='%@';"
            "  el.dispatchEvent(new Event('change',{bubbles:true}));"
            "  results.push({selector:'%@',ok:true})"
            "}"
            "else if(el.type==='checkbox'||el.type==='radio'){"
            "  var want=('%@'==='true'||'%@'==='1'||'%@'==='on');"
            "  if(el.checked!==want){el.click()}"
            "  results.push({selector:'%@',ok:true})"
            "}"
            "else{"
            "  var nativeSetter=Object.getOwnPropertyDescriptor("
            "    window.HTMLInputElement.prototype,'value').set||"
            "    Object.getOwnPropertyDescriptor("
            "    window.HTMLTextAreaElement.prototype,'value').set;"
            "  if(nativeSetter)nativeSetter.call(el,'%@');"
            "  else el.value='%@';"
            "  el.dispatchEvent(new Event('input',{bubbles:true}));"
            "  el.dispatchEvent(new Event('change',{bubbles:true}));"
            "  results.push({selector:'%@',ok:true})"
            "}",
            escapedSel, escapedSel,
            escapedVal, escapedSel,
            escapedVal, escapedVal, escapedVal, escapedSel,
            escapedVal, escapedVal, escapedSel
        ];
    }

    [js appendString:@"return JSON.stringify({ok:true,results:results})})()"];

    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) { result = @{@"ok": @NO, @"error": @"no active webview"}; return; }

        __block NSDictionary *response = nil;
        __block BOOL done = NO;

        [wv evaluateJavaScript:js completionHandler:^(id res, NSError *error) {
            if (error) {
                response = @{@"ok": @NO, @"error": error.localizedDescription ?: @"unknown"};
            } else if (res && [res isKindOfClass:[NSString class]]) {
                NSData *data = [(NSString *)res dataUsingEncoding:NSUTF8StringEncoding];
                response = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
            done = YES;
        }];

        NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                beforeDate:timeout]) {
            if ([timeout timeIntervalSinceNow] <= 0) break;
        }

        if (!done) result = @{@"ok": @NO, @"error": @"fill timeout"};
        else if (response) result = response;
        else result = @{@"ok": @NO, @"error": @"fill failed"};
    });
    return result ?: @{@"ok": @NO, @"error": @"fill failed"};
}
```

**Step 2: Add handle_fill and route**

```c
static void handle_fill(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_fill(json, ctx));
}
```

Route (after `/click`):

```c
} else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/fill") == 0) {
    handle_fill(client_fd, &req, ctx);
}
```

**Step 3: Add to batch handler**

After the `"click"` case:

```c
} else if ([type isEqualToString:@"fill"]) {
    result = do_fill(step, ctx);
}
```

**Step 4: Build and smoke test**

```bash
make clean && make
# Terminal 1: ./swim --serve 9111 https://duckduckgo.com
# Terminal 2:
curl -s http://localhost:9111/interact | python3 -c "import sys,json; d=json.load(sys.stdin); [print(e['selector'],e.get('label','')) for e in d['elements'][:10]]"
# Get the search input selector, then:
curl -s -X POST http://localhost:9111/fill \
  -d '{"selector":"input[name=\"q\"]","value":"swim browser"}' | python3 -m json.tool
# Expected: {"ok":true,"results":[{"selector":"input[name=\"q\"]","ok":true}]}
```

**Step 5: Commit**

```bash
git add serve.m
git commit -m "Add /fill endpoint for form field manipulation"
```

---

### Task 4: Add /wait_for endpoint — wait for CSS selector to appear

The existing `/wait` only waits for page load to complete. LOB apps need "wait until this element appears" (e.g., after AJAX loads a table, after a modal pops up). This adds a `/wait_for` endpoint that polls for a CSS selector.

**Files:**
- Modify: `serve.m` — add do_wait_for, handle_wait_for, route, batch type

**Step 1: Add do_wait_for to serve.m**

After `do_wait`:

```c
static NSDictionary *do_wait_for(NSDictionary *json, ServeContext *ctx) {
    NSString *selector = json[@"selector"];
    if (!selector) return @{@"ok": @NO, @"error": @"missing selector"};

    NSNumber *timeout_ms = json[@"timeout"];
    double timeout_sec = timeout_ms ? [timeout_ms doubleValue] / 1000.0 : 10.0;
    if (timeout_sec > 30.0) timeout_sec = 30.0;
    if (timeout_sec < 0.1) timeout_sec = 0.1;

    NSString *escapedSel = [selector stringByReplacingOccurrencesOfString:@"'"
                                                              withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:
        @"!!document.querySelector('%@')", escapedSel];

    __block bool found = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        WKWebView *wv = (__bridge WKWebView *)ui_get_active_webview(ctx->ui);
        if (!wv) return;

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_sec];
        while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
            __block BOOL done = NO;
            __block BOOL exists = NO;

            [wv evaluateJavaScript:js completionHandler:^(id res, NSError *error) {
                if (!error && [res isKindOfClass:[NSNumber class]]) {
                    exists = [res boolValue];
                }
                done = YES;
            }];

            NSDate *pollEnd = [NSDate dateWithTimeIntervalSinceNow:0.2];
            while (!done && [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                                     beforeDate:pollEnd]) {
                if ([pollEnd timeIntervalSinceNow] <= 0) break;
            }

            if (exists) { found = true; break; }

            // Sleep 100ms between polls
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    });
    return @{@"ok": @YES, @"found": @(found)};
}
```

**Step 2: Add handle_wait_for and route**

```c
static void handle_wait_for(int fd, HTTPRequest *req, ServeContext *ctx) {
    NSDictionary *json = parse_json_body(req->body, req->body_len);
    send_dict(fd, do_wait_for(json, ctx));
}
```

Route (after `/wait`):

```c
} else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/wait_for") == 0) {
    handle_wait_for(client_fd, &req, ctx);
}
```

**Step 3: Add to batch handler**

After the `"wait"` case:

```c
} else if ([type isEqualToString:@"wait_for"]) {
    result = do_wait_for(step, ctx);
}
```

**Step 4: Build and smoke test**

```bash
make clean && make
# Terminal 1: ./swim --serve 9111 https://example.com
# Terminal 2:
# Test: element that exists (should return found:true quickly)
curl -s -X POST http://localhost:9111/wait_for \
  -d '{"selector":"h1","timeout":5000}' | python3 -m json.tool
# Expected: {"ok":true,"found":true}

# Test: element that doesn't exist (should timeout)
curl -s -X POST http://localhost:9111/wait_for \
  -d '{"selector":"#nonexistent","timeout":1000}' | python3 -m json.tool
# Expected: {"ok":true,"found":false}
```

**Step 5: Commit**

```bash
git add serve.m
git commit -m "Add /wait_for endpoint to poll for CSS selector appearance"
```

---

### Task 5: Add interact, fill, wait_for methods to swim-mcp.c

Wire the three new endpoints into the MCP meta-tool so Claude Code can use them.

**Files:**
- Modify: `swim-mcp.c` — update kToolsList, add handlers in handle_tool_call

**Step 1: Update kToolsList**

Add three new methods to the enum and new parameters to the schema. Replace the existing `kToolsList` definition:

```c
static const char *kToolsList =
    "{\"tools\":["
    "{\"name\":\"swim\","
    "\"description\":\"Control the swim browser. Methods: navigate (url), screenshot, extract, "
    "interact, fill (selector+value or fields[]), wait_for (selector, timeout?), "
    "execute (command), action (action, count?), state, click (selector|text), key (key)\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{"
    "\"method\":{\"type\":\"string\",\"enum\":[\"navigate\",\"screenshot\",\"extract\","
    "\"interact\",\"fill\",\"wait_for\","
    "\"execute\",\"action\",\"state\",\"click\",\"key\"],"
    "\"description\":\"The operation to perform\"},"
    "\"url\":{\"type\":\"string\",\"description\":\"URL to navigate to (navigate)\"},"
    "\"command\":{\"type\":\"string\",\"description\":\"Command to run (execute)\"},"
    "\"action\":{\"type\":\"string\",\"description\":\"Action name (action)\"},"
    "\"count\":{\"type\":\"integer\",\"description\":\"Repeat count (action)\"},"
    "\"selector\":{\"type\":\"string\",\"description\":\"CSS selector (click, fill, wait_for)\"},"
    "\"text\":{\"type\":\"string\",\"description\":\"Text content to match (click)\"},"
    "\"key\":{\"type\":\"string\",\"description\":\"Key to send (key)\"},"
    "\"value\":{\"type\":\"string\",\"description\":\"Value to set (fill)\"},"
    "\"fields\":{\"type\":\"array\",\"description\":\"Array of {selector,value} pairs (fill)\","
    "\"items\":{\"type\":\"object\",\"properties\":{"
    "\"selector\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}}}},"
    "\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in ms (wait_for, default 10000)\"}},"
    "\"required\":[\"method\"]}}"
    "]}";
```

**Step 2: Add interact handler**

In `handle_tool_call`, after the `"extract"` case, add:

```c
    if (strcmp(name, "interact") == 0) {
        char *resp = http_get("/interact");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }
```

**Step 3: Add fill handler**

After the interact handler:

```c
    if (strcmp(name, "fill") == 0) {
        // Support both single-field and multi-field
        char *selector = json_get_string(arguments, "selector");
        char *value = json_get_string(arguments, "value");
        // Check for fields array
        char *fields_raw = NULL;
        const char *fa = strstr(arguments, "\"fields\"");
        if (fa) {
            // Find the array start
            const char *p = fa + 8;
            while (*p && *p != '[') p++;
            if (*p == '[') {
                int depth = 0;
                const char *start = p;
                while (*p) {
                    if (*p == '[') depth++;
                    else if (*p == ']') { depth--; if (depth == 0) { p++; break; } }
                    else if (*p == '"') { p++; while (*p && *p != '"') { if (*p == '\\') p++; p++; } }
                    p++;
                }
                int len = (int)(p - start);
                fields_raw = malloc(len + 1);
                memcpy(fields_raw, start, len);
                fields_raw[len] = '\0';
            }
        }

        char *body;
        if (fields_raw) {
            int bsize = (int)strlen(fields_raw) + 64;
            body = malloc(bsize);
            snprintf(body, bsize, "{\"fields\":%s}", fields_raw);
            free(fields_raw);
        } else if (selector) {
            char *esc_sel = json_escape(selector);
            char *esc_val = value ? json_escape(value) : strdup("");
            int bsize = (int)strlen(esc_sel) + (int)strlen(esc_val) + 64;
            body = malloc(bsize);
            snprintf(body, bsize, "{\"selector\":\"%s\",\"value\":\"%s\"}", esc_sel, esc_val);
            free(esc_sel);
            free(esc_val);
        } else {
            free(selector); free(value);
            return strdup("{\"error\":\"missing selector or fields\"}");
        }
        free(selector); free(value);
        char *resp = http_post("/fill", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }
```

**Step 4: Add wait_for handler**

After the fill handler:

```c
    if (strcmp(name, "wait_for") == 0) {
        char *selector = json_get_string(arguments, "selector");
        if (!selector) return strdup("{\"error\":\"missing selector\"}");
        char *escaped = json_escape(selector);
        int timeout = 0;
        bool has_timeout = json_get_int(arguments, "timeout", &timeout);
        int bsize = (int)strlen(escaped) + 128;
        char *body = malloc(bsize);
        if (has_timeout && timeout > 0) {
            snprintf(body, bsize, "{\"selector\":\"%s\",\"timeout\":%d}", escaped, timeout);
        } else {
            snprintf(body, bsize, "{\"selector\":\"%s\"}", escaped);
        }
        free(escaped);
        free(selector);
        char *resp = http_post("/wait_for", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }
```

**Step 5: Build**

```bash
make clean && make all
```

**Step 6: Smoke test via MCP**

Restart Claude Code session. Use the swim tool:
- `swim interact` — should return element map
- `swim fill selector=<input_selector> value="test"` — should fill field
- `swim wait_for selector="h1"` — should return found:true

**Step 7: Commit**

```bash
git add swim-mcp.c
git commit -m "Add interact, fill, wait_for methods to MCP meta-tool"
```

---

### Task 6: Update docs and integration test

Update CLAUDE.md with the new endpoints and methods.

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update CLAUDE.md API Server section**

Update the endpoints line:

```markdown
Endpoints: /health, /state, /screenshot, /extract, /interact, /click, /fill, /wait, /wait_for, /action, /command, /key, /eval, /batch, /resize
```

Update the MCP tools line:

```markdown
Tools: navigate, screenshot, extract, interact, fill, wait_for, execute, action, state, click, key
```

**Step 2: End-to-end test**

With swim running (`./swim --serve 9111`), test the full agent workflow:

```bash
# 1. Navigate
curl -s -X POST http://localhost:9111/command -d '{"command":"open https://duckduckgo.com"}'

# 2. Wait for page
curl -s -X POST http://localhost:9111/wait -d '{"timeout":5000}'

# 3. Discover form elements
curl -s http://localhost:9111/interact | python3 -m json.tool

# 4. Fill search box
curl -s -X POST http://localhost:9111/fill -d '{"selector":"input[name=q]","value":"swim browser"}'

# 5. Click search button
curl -s -X POST http://localhost:9111/click -d '{"text":"Search"}'

# 6. Wait for results
curl -s -X POST http://localhost:9111/wait_for -d '{"selector":".result","timeout":5000}'

# 7. Extract results
curl -s http://localhost:9111/extract | python3 -m json.tool
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document interact, fill, wait_for endpoints and MCP methods"
```

---

Plan complete and saved to `docs/plans/2026-03-09-interaction-map.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints

Which approach?
