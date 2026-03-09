#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <errno.h>

// --- Configuration ---

static int g_port = 9111;

// --- Simple JSON helpers (no dependencies) ---

// Find a string value for a key in a JSON object (simple flat parser)
// Returns malloc'd string or NULL. Caller must free.
static char *json_get_string(const char *json, const char *key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = json;
    while ((p = strstr(p, search)) != NULL) {
        p += strlen(search);
        // Skip whitespace, require colon (must be a key, not a value)
        const char *q = p;
        while (*q == ' ' || *q == '\t') q++;
        if (*q != ':') continue;
        q++; // skip colon
        while (*q == ' ' || *q == '\t') q++;
        if (*q != '"') return NULL;
        q++;
        const char *end = q;
        while (*end && *end != '"') {
            if (*end == '\\') end++;
            end++;
        }
        int len = (int)(end - q);
        char *result = malloc(len + 1);
        // Unescape JSON string: \" -> ", \\ -> \, \n -> newline, etc.
        int j = 0;
        for (int i = 0; i < len; i++) {
            if (q[i] == '\\' && i + 1 < len) {
                i++;
                switch (q[i]) {
                    case '"':  result[j++] = '"'; break;
                    case '\\': result[j++] = '\\'; break;
                    case 'n':  result[j++] = '\n'; break;
                    case 'r':  result[j++] = '\r'; break;
                    case 't':  result[j++] = '\t'; break;
                    case '/':  result[j++] = '/'; break;
                    default:   result[j++] = '\\'; result[j++] = q[i]; break;
                }
            } else {
                result[j++] = q[i];
            }
        }
        result[j] = '\0';
        return result;
    }
    return NULL;
}

// Find an integer value for a key
static bool json_get_int(const char *json, const char *key, int *out) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = json;
    while ((p = strstr(p, search)) != NULL) {
        p += strlen(search);
        const char *q = p;
        while (*q == ' ' || *q == '\t') q++;
        if (*q != ':') continue;
        q++;
        while (*q == ' ' || *q == '\t') q++;
        if (*q != '-' && (*q < '0' || *q > '9')) return false;
        *out = atoi(q);
        return true;
    }
    return false;
}

// Extract the "params" object as a raw substring
static char *json_get_object(const char *json, const char *key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return NULL;
    p += strlen(search);
    while (*p && *p != '{') p++;
    if (*p != '{') return NULL;

    int depth = 0;
    const char *start = p;
    while (*p) {
        if (*p == '{') depth++;
        else if (*p == '}') { depth--; if (depth == 0) { p++; break; } }
        else if (*p == '"') { p++; while (*p && *p != '"') { if (*p == '\\') p++; p++; } }
        if (*p) p++;
    }
    int len = (int)(p - start);
    char *result = malloc(len + 1);
    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

// --- HTTP Client ---

static char *http_request(const char *method, const char *path,
                          const char *body, int *out_len) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NULL;

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(g_port),
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return NULL;
    }

    // Send request
    char header[1024];
    int body_len = body ? (int)strlen(body) : 0;
    int hlen = snprintf(header, sizeof(header),
        "%s %s HTTP/1.1\r\n"
        "Host: localhost\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n\r\n",
        method, path, body_len);

    write(fd, header, hlen);
    if (body && body_len > 0) write(fd, body, body_len);

    // Read response
    int cap = 65536;
    char *buf = malloc(cap);
    int total = 0;
    while (1) {
        if (total >= cap - 1) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
        int n = (int)read(fd, buf + total, cap - 1 - total);
        if (n <= 0) break;
        total += n;
    }
    buf[total] = '\0';
    close(fd);

    // Skip HTTP headers, find body
    char *body_start = strstr(buf, "\r\n\r\n");
    if (!body_start) { free(buf); return NULL; }
    body_start += 4;

    int resp_len = total - (int)(body_start - buf);
    char *result = malloc(resp_len + 1);
    memcpy(result, body_start, resp_len);
    result[resp_len] = '\0';
    if (out_len) *out_len = resp_len;

    free(buf);
    return result;
}

static char *http_get(const char *path) {
    return http_request("GET", path, NULL, NULL);
}

static char *http_post(const char *path, const char *body) {
    return http_request("POST", path, body, NULL);
}

// Get raw binary response (for screenshots)
static char *http_get_raw(const char *path, int *out_len) {
    return http_request("GET", path, NULL, out_len);
}

// --- Base64 encoder (for screenshot PNG) ---

static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *base64_encode(const unsigned char *data, int len) {
    int out_len = 4 * ((len + 2) / 3);
    char *out = malloc(out_len + 1);
    int i, j;
    for (i = 0, j = 0; i < len - 2; i += 3) {
        out[j++] = b64_table[(data[i] >> 2) & 0x3F];
        out[j++] = b64_table[((data[i] & 0x3) << 4) | ((data[i+1] >> 4) & 0xF)];
        out[j++] = b64_table[((data[i+1] & 0xF) << 2) | ((data[i+2] >> 6) & 0x3)];
        out[j++] = b64_table[data[i+2] & 0x3F];
    }
    if (i < len) {
        out[j++] = b64_table[(data[i] >> 2) & 0x3F];
        if (i == len - 1) {
            out[j++] = b64_table[(data[i] & 0x3) << 4];
            out[j++] = '=';
        } else {
            out[j++] = b64_table[((data[i] & 0x3) << 4) | ((data[i+1] >> 4) & 0xF)];
            out[j++] = b64_table[(data[i+1] & 0xF) << 2];
        }
        out[j++] = '=';
    }
    out[j] = '\0';
    return out;
}

static FILE *g_dbg = NULL;

// --- MCP Protocol ---

static void send_mcp(const char *json) {
    int json_len = (int)strlen(json);
    // Send as newline-delimited JSON (matching how Claude Code sends)
    int total_len = json_len + 1;
    char *buf = malloc(total_len);
    memcpy(buf, json, json_len);
    buf[json_len] = '\n';
    if (g_dbg) { fprintf(g_dbg, "\n[sending %d bytes]\n%.*s\n", total_len, json_len, buf); fflush(g_dbg); }
    int written = 0;
    while (written < total_len) {
        int n = (int)write(STDOUT_FILENO, buf + written, total_len - written);
        if (g_dbg) { fprintf(g_dbg, "[write returned %d, errno=%d]\n", n, errno); fflush(g_dbg); }
        if (n <= 0) break;
        written += n;
    }
    free(buf);
}

static void send_mcp_result(const char *id_str, int id_int, bool id_is_string,
                            const char *result_json) {
    int rlen = (int)strlen(result_json);
    int buf_size = rlen + 256;
    char *buf = malloc(buf_size);
    if (id_is_string) {
        snprintf(buf, buf_size,
            "{\"jsonrpc\":\"2.0\",\"id\":\"%s\",\"result\":%s}",
            id_str, result_json);
    } else {
        snprintf(buf, buf_size,
            "{\"jsonrpc\":\"2.0\",\"id\":%d,\"result\":%s}",
            id_int, result_json);
    }
    send_mcp(buf);
    free(buf);
}

static void send_mcp_error(const char *id_str, int id_int, bool id_is_string,
                           int code, const char *message) {
    char buf[4096];
    if (id_is_string) {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":\"%s\","
            "\"error\":{\"code\":%d,\"message\":\"%s\"}}",
            id_str, code, message);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"jsonrpc\":\"2.0\",\"id\":%d,"
            "\"error\":{\"code\":%d,\"message\":\"%s\"}}",
            id_int, code, message);
    }
    send_mcp(buf);
}

// --- Tool Definitions ---

static const char *kToolsList =
    "{\"tools\":["
    "{\"name\":\"swim\","
    "\"description\":\"Control the swim browser. Methods: navigate (url), screenshot, pdf, extract, "
    "navigate_back, navigate_forward, eval (js), "
    "interact, fill (selector+value or fields[]), wait_for (selector|url_contains, timeout?), "
    "console, query (selector, attribute?, all?), tab (index), select (selector, text|value), "
    "scroll (selector), storage (type, action?, key?, value?), "
    "execute (command), action (action, count?), state, click (selector|text), hover (selector), key (key)\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{"
    "\"method\":{\"type\":\"string\",\"enum\":[\"navigate\",\"navigate_back\",\"navigate_forward\","
    "\"screenshot\",\"pdf\",\"extract\","
    "\"interact\",\"fill\",\"wait_for\",\"console\",\"query\",\"tab\",\"select\","
    "\"scroll\",\"storage\","
    "\"execute\",\"action\",\"state\",\"click\",\"hover\",\"key\",\"eval\"],"
    "\"description\":\"The operation to perform\"},"
    "\"url\":{\"type\":\"string\",\"description\":\"URL to navigate to (navigate)\"},"
    "\"command\":{\"type\":\"string\",\"description\":\"Command to run (execute)\"},"
    "\"action\":{\"type\":\"string\",\"description\":\"Action name (action)\"},"
    "\"count\":{\"type\":\"integer\",\"description\":\"Repeat count (action)\"},"
    "\"selector\":{\"type\":\"string\",\"description\":\"CSS selector (click, fill, wait_for, query, select)\"},"
    "\"text\":{\"type\":\"string\",\"description\":\"Text to match (click) or option text (select)\"},"
    "\"key\":{\"type\":\"string\",\"description\":\"Key to send (key)\"},"
    "\"js\":{\"type\":\"string\",\"description\":\"JavaScript to evaluate in page (eval)\"},"
    "\"value\":{\"type\":\"string\",\"description\":\"Value to set (fill, select)\"},"
    "\"fields\":{\"type\":\"array\",\"description\":\"Array of {selector,value} pairs (fill)\","
    "\"items\":{\"type\":\"object\",\"properties\":{"
    "\"selector\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}}}},"
    "\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in ms (wait_for, default 10000)\"},"
    "\"url_contains\":{\"type\":\"string\",\"description\":\"URL substring to wait for (wait_for)\"},"
    "\"attribute\":{\"type\":\"string\",\"description\":\"Attribute name to read (query)\"},"
    "\"all\":{\"type\":\"boolean\",\"description\":\"Query all matching elements (query)\"},"
    "\"index\":{\"type\":\"integer\",\"description\":\"Tab index to switch to (tab)\"},"
    "\"type\":{\"type\":\"string\",\"description\":\"Storage type: cookie, localStorage, sessionStorage (storage)\"}},"
    "\"required\":[\"method\"]}}"
    "]}";

// --- Tool Call Handlers ---

// Helper: escape a string for JSON embedding
static char *json_escape(const char *str) {
    int len = (int)strlen(str);
    int cap = len * 2 + 1;
    char *out = malloc(cap);
    int j = 0;
    for (int i = 0; i < len && j < cap - 2; i++) {
        if (str[i] == '"' || str[i] == '\\') out[j++] = '\\';
        else if (str[i] == '\n') { out[j++] = '\\'; out[j++] = 'n'; continue; }
        else if (str[i] == '\r') { out[j++] = '\\'; out[j++] = 'r'; continue; }
        else if (str[i] == '\t') { out[j++] = '\\'; out[j++] = 't'; continue; }
        out[j++] = str[i];
    }
    out[j] = '\0';
    return out;
}

static char *handle_tool_call(const char *name, const char *arguments) {
    if (strcmp(name, "navigate") == 0) {
        char *url = json_get_string(arguments, "url");
        if (!url) return strdup("{\"error\":\"missing url\"}");
        char *escaped = json_escape(url);
        int body_size = (int)strlen(escaped) + 64;
        char *body = malloc(body_size);
        snprintf(body, body_size, "{\"command\":\"open %s\"}", escaped);
        free(escaped);
        free(url);
        char *resp = http_post("/command", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "navigate_back") == 0) {
        char *resp = http_post("/action", "{\"action\":\"back\"}");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "navigate_forward") == 0) {
        char *resp = http_post("/action", "{\"action\":\"forward\"}");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "screenshot") == 0) {
        int len = 0;
        char *raw = http_get_raw("/screenshot", &len);
        if (!raw || len <= 0) {
            free(raw);
            return strdup("{\"error\":\"screenshot failed\"}");
        }
        // Return base64-encoded PNG for MCP image content
        char *b64 = base64_encode((unsigned char *)raw, len);
        free(raw);
        // Build MCP image content response
        int resp_size = (int)strlen(b64) + 256;
        char *resp = malloc(resp_size);
        snprintf(resp, resp_size,
            "{\"type\":\"image\",\"data\":\"%s\",\"mimeType\":\"image/png\"}", b64);
        free(b64);
        return resp;
    }

    if (strcmp(name, "pdf") == 0) {
        int len = 0;
        char *raw = http_get_raw("/pdf", &len);
        if (!raw || len <= 0) {
            free(raw);
            return strdup("{\"error\":\"pdf failed\"}");
        }
        char *b64 = base64_encode((unsigned char *)raw, len);
        free(raw);
        int resp_size = (int)strlen(b64) + 256;
        char *resp = malloc(resp_size);
        snprintf(resp, resp_size,
            "{\"type\":\"resource\",\"data\":\"%s\",\"mimeType\":\"application/pdf\"}", b64);
        free(b64);
        return resp;
    }

    if (strcmp(name, "extract") == 0) {
        char *resp = http_get("/extract");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "interact") == 0) {
        char *resp = http_get("/interact");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "console") == 0) {
        char *resp = http_get("/console");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "fill") == 0) {
        // Support both single-field and multi-field
        char *selector = json_get_string(arguments, "selector");
        char *value = json_get_string(arguments, "value");
        // Check for fields array — pass raw JSON through
        const char *fa = strstr(arguments, "\"fields\"");
        char *body = NULL;

        if (fa) {
            // Find the array
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
                int bsize = len + 64;
                body = malloc(bsize);
                snprintf(body, bsize, "{\"fields\":%.*s}", len, start);
            }
        }
        if (!body && selector) {
            char *esc_sel = json_escape(selector);
            char *esc_val = value ? json_escape(value) : strdup("");
            int bsize = (int)strlen(esc_sel) + (int)strlen(esc_val) + 64;
            body = malloc(bsize);
            snprintf(body, bsize, "{\"selector\":\"%s\",\"value\":\"%s\"}", esc_sel, esc_val);
            free(esc_sel);
            free(esc_val);
        }
        free(selector); free(value);
        if (!body) return strdup("{\"error\":\"missing selector or fields\"}");
        char *resp = http_post("/fill", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "wait_for") == 0) {
        char *selector = json_get_string(arguments, "selector");
        char *url_contains = json_get_string(arguments, "url_contains");
        if (!selector && !url_contains)
            return strdup("{\"error\":\"missing selector or url_contains\"}");
        int timeout = 0;
        bool has_timeout = json_get_int(arguments, "timeout", &timeout);
        char *body;
        if (selector) {
            char *escaped = json_escape(selector);
            int bsize = (int)strlen(escaped) + 128;
            body = malloc(bsize);
            if (has_timeout && timeout > 0)
                snprintf(body, bsize, "{\"selector\":\"%s\",\"timeout\":%d}", escaped, timeout);
            else
                snprintf(body, bsize, "{\"selector\":\"%s\"}", escaped);
            free(escaped);
        } else {
            char *escaped = json_escape(url_contains);
            int bsize = (int)strlen(escaped) + 128;
            body = malloc(bsize);
            if (has_timeout && timeout > 0)
                snprintf(body, bsize, "{\"url_contains\":\"%s\",\"timeout\":%d}", escaped, timeout);
            else
                snprintf(body, bsize, "{\"url_contains\":\"%s\"}", escaped);
            free(escaped);
        }
        free(selector); free(url_contains);
        char *resp = http_post("/wait_for", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "query") == 0) {
        char *selector = json_get_string(arguments, "selector");
        if (!selector) return strdup("{\"error\":\"missing selector\"}");
        char *escaped = json_escape(selector);
        char *attribute = json_get_string(arguments, "attribute");
        // Check for "all" boolean
        const char *all_str = strstr(arguments, "\"all\"");
        bool all = false;
        if (all_str) {
            const char *p = all_str + 5;
            while (*p == ' ' || *p == ':' || *p == '\t') p++;
            if (strncmp(p, "true", 4) == 0) all = true;
        }
        int bsize = (int)strlen(escaped) + (attribute ? (int)strlen(attribute) : 0) + 128;
        char *body = malloc(bsize);
        if (attribute) {
            char *esc_attr = json_escape(attribute);
            if (all)
                snprintf(body, bsize,
                    "{\"selector\":\"%s\",\"attribute\":\"%s\",\"all\":true}", escaped, esc_attr);
            else
                snprintf(body, bsize,
                    "{\"selector\":\"%s\",\"attribute\":\"%s\"}", escaped, esc_attr);
            free(esc_attr);
        } else if (all) {
            snprintf(body, bsize, "{\"selector\":\"%s\",\"all\":true}", escaped);
        } else {
            snprintf(body, bsize, "{\"selector\":\"%s\"}", escaped);
        }
        free(escaped); free(selector); free(attribute);
        char *resp = http_post("/query", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "tab") == 0) {
        int index = 0;
        if (!json_get_int(arguments, "index", &index))
            return strdup("{\"error\":\"missing index\"}");
        char body[64];
        snprintf(body, sizeof(body), "{\"index\":%d}", index);
        char *resp = http_post("/tab", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "select") == 0) {
        char *selector = json_get_string(arguments, "selector");
        if (!selector) return strdup("{\"error\":\"missing selector\"}");
        char *text = json_get_string(arguments, "text");
        char *value = json_get_string(arguments, "value");
        if (!text && !value) {
            free(selector);
            return strdup("{\"error\":\"missing text or value\"}");
        }
        char *esc_sel = json_escape(selector);
        char *body;
        if (text) {
            char *esc_text = json_escape(text);
            int bsize = (int)strlen(esc_sel) + (int)strlen(esc_text) + 64;
            body = malloc(bsize);
            snprintf(body, bsize,
                "{\"selector\":\"%s\",\"text\":\"%s\"}", esc_sel, esc_text);
            free(esc_text);
        } else {
            char *esc_val = json_escape(value);
            int bsize = (int)strlen(esc_sel) + (int)strlen(esc_val) + 64;
            body = malloc(bsize);
            snprintf(body, bsize,
                "{\"selector\":\"%s\",\"value\":\"%s\"}", esc_sel, esc_val);
            free(esc_val);
        }
        free(esc_sel); free(selector); free(text); free(value);
        char *resp = http_post("/select", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "scroll") == 0) {
        char *selector = json_get_string(arguments, "selector");
        if (!selector) return strdup("{\"error\":\"missing selector\"}");
        char *escaped = json_escape(selector);
        int bsize = (int)strlen(escaped) + 128;
        char *body = malloc(bsize);
        snprintf(body, bsize, "{\"selector\":\"%s\"}", escaped);
        free(escaped); free(selector);
        char *resp = http_post("/scroll", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "storage") == 0) {
        char *type = json_get_string(arguments, "type");
        if (!type) return strdup("{\"error\":\"missing type\"}");
        char *action = json_get_string(arguments, "action");
        char *key = json_get_string(arguments, "key");
        char *value = json_get_string(arguments, "value");

        char *esc_type = json_escape(type);
        char *esc_action = action ? json_escape(action) : strdup("get");
        char *esc_key = key ? json_escape(key) : NULL;
        char *esc_value = value ? json_escape(value) : NULL;

        int bsize = 512;
        char *body = malloc(bsize);
        if (esc_key && esc_value) {
            snprintf(body, bsize,
                "{\"type\":\"%s\",\"action\":\"%s\",\"key\":\"%s\",\"value\":\"%s\"}",
                esc_type, esc_action, esc_key, esc_value);
        } else if (esc_key) {
            snprintf(body, bsize,
                "{\"type\":\"%s\",\"action\":\"%s\",\"key\":\"%s\"}",
                esc_type, esc_action, esc_key);
        } else {
            snprintf(body, bsize,
                "{\"type\":\"%s\",\"action\":\"%s\"}",
                esc_type, esc_action);
        }

        free(esc_type); free(esc_action); free(esc_key); free(esc_value);
        free(type); free(action); free(key); free(value);
        char *resp = http_post("/storage", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "execute") == 0) {
        char *cmd = json_get_string(arguments, "command");
        if (!cmd) return strdup("{\"error\":\"missing command\"}");
        char *escaped = json_escape(cmd);
        char body[4096];
        snprintf(body, sizeof(body), "{\"command\":\"%s\"}", escaped);
        free(escaped);
        free(cmd);
        char *resp = http_post("/command", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "action") == 0) {
        char *action = json_get_string(arguments, "action");
        if (!action) return strdup("{\"error\":\"missing action\"}");
        char *escaped = json_escape(action);
        int count = 0;
        bool has_count = json_get_int(arguments, "count", &count);
        char body[512];
        if (has_count && count > 0) {
            snprintf(body, sizeof(body),
                "{\"action\":\"%s\",\"count\":%d}", escaped, count);
        } else {
            snprintf(body, sizeof(body), "{\"action\":\"%s\"}", escaped);
        }
        free(escaped);
        free(action);
        char *resp = http_post("/action", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "state") == 0) {
        char *resp = http_get("/state");
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "click") == 0) {
        char *selector = json_get_string(arguments, "selector");
        char *text = json_get_string(arguments, "text");
        char body[4096];
        if (selector) {
            char *escaped = json_escape(selector);
            snprintf(body, sizeof(body), "{\"selector\":\"%s\"}", escaped);
            free(escaped);
        } else if (text) {
            char *escaped = json_escape(text);
            snprintf(body, sizeof(body), "{\"text\":\"%s\"}", escaped);
            free(escaped);
        } else {
            free(selector); free(text);
            return strdup("{\"error\":\"missing selector or text\"}");
        }
        free(selector); free(text);
        char *resp = http_post("/click", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "hover") == 0) {
        char *selector = json_get_string(arguments, "selector");
        if (!selector) return strdup("{\"error\":\"missing selector\"}");
        char *escaped = json_escape(selector);
        char body[4096];
        snprintf(body, sizeof(body), "{\"selector\":\"%s\"}", escaped);
        free(escaped);
        free(selector);
        char *resp = http_post("/hover", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "key") == 0) {
        char *key = json_get_string(arguments, "key");
        if (!key) return strdup("{\"error\":\"missing key\"}");
        char *escaped = json_escape(key);
        char body[256];
        snprintf(body, sizeof(body), "{\"key\":\"%s\"}", escaped);
        free(escaped);
        free(key);
        char *resp = http_post("/key", body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    if (strcmp(name, "eval") == 0) {
        char *js = json_get_string(arguments, "js");
        if (!js) return strdup("{\"error\":\"missing js\"}");
        char *escaped = json_escape(js);
        int bsize = (int)strlen(escaped) + 64;
        char *body = malloc(bsize);
        snprintf(body, bsize, "{\"js\":\"%s\"}", escaped);
        free(escaped); free(js);
        char *resp = http_post("/eval", body);
        free(body);
        return resp ? resp : strdup("{\"error\":\"connection failed\"}");
    }

    return strdup("{\"error\":\"unknown tool\"}");
}

// --- Read MCP message from stdin ---

// Read a single byte from stdin (raw fd, no buffering issues)
static int read_byte(void) {
    unsigned char c;
    int n = (int)read(STDIN_FILENO, &c, 1);
    if (g_dbg && n == 1) { fprintf(g_dbg, "%c", c); fflush(g_dbg); }
    if (g_dbg && n != 1) { fprintf(g_dbg, "\n[EOF n=%d errno=%d]\n", n, errno); fflush(g_dbg); }
    return (n == 1) ? c : -1;
}

// Read a line from stdin into buf, return length (0 on EOF)
static int read_line(char *buf, int cap) {
    int i = 0;
    while (i < cap - 1) {
        int c = read_byte();
        if (c < 0) return 0;
        buf[i++] = (char)c;
        if (c == '\n') break;
    }
    buf[i] = '\0';
    return i;
}

static char *read_mcp_message(void) {
    // Read first line
    int cap = 65536;
    char *buf = malloc(cap);
    int len = read_line(buf, cap);
    if (len <= 0) { free(buf); return NULL; }

    // Newline-delimited JSON: line starts with '{'
    if (buf[0] == '{') {
        // Strip trailing newline/cr
        while (len > 0 && (buf[len-1] == '\n' || buf[len-1] == '\r')) buf[--len] = '\0';
        return buf;
    }

    // Content-Length framed (LSP-style)
    int content_length = 0;
    if (strncmp(buf, "Content-Length:", 15) == 0) {
        content_length = atoi(buf + 15);
    }

    // Read remaining headers until empty line
    char line[256];
    while (read_line(line, sizeof(line)) > 0) {
        if (strncmp(line, "Content-Length:", 15) == 0) {
            content_length = atoi(line + 15);
        }
        if (strcmp(line, "\r\n") == 0 || strcmp(line, "\n") == 0) break;
    }

    free(buf);
    if (content_length <= 0 || content_length > 10485760) return NULL;

    char *body = malloc(content_length + 1);
    int total = 0;
    while (total < content_length) {
        int n = (int)read(STDIN_FILENO, body + total, content_length - total);
        if (n <= 0) { free(body); return NULL; }
        total += n;
    }
    body[content_length] = '\0';
    return body;
}

// --- Main ---

int main(int argc, char *argv[]) {
    // Parse args
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            g_port = atoi(argv[++i]);
        }
    }

    // Ignore SIGPIPE (can happen on closed sockets)
    signal(SIGPIPE, SIG_IGN);

    // Debug: log to file
    FILE *dbg = fopen("/tmp/swim-mcp.log", "w");
    if (dbg) { fprintf(dbg, "started, port=%d, stdin=%d, stdout=%d\n", g_port, STDIN_FILENO, STDOUT_FILENO); fflush(dbg); }
    g_dbg = dbg;

    // MCP message loop
    while (1) {
        if (g_dbg) { fprintf(g_dbg, "\n[waiting for message]\n"); fflush(g_dbg); }
        char *msg = read_mcp_message();
        if (!msg) { if (g_dbg) { fprintf(g_dbg, "\n[read_mcp_message returned NULL]\n"); fflush(g_dbg); } break; }

        char *method = json_get_string(msg, "method");
        char *id_str = json_get_string(msg, "id");
        int id_int = 0;
        bool id_is_string = (id_str != NULL);
        if (!id_is_string) json_get_int(msg, "id", &id_int);

        if (!method) {
            free(msg);
            free(id_str);
            continue;
        }

        if (strcmp(method, "initialize") == 0) {
            send_mcp_result(id_str, id_int, id_is_string,
                "{\"protocolVersion\":\"2025-11-25\","
                "\"capabilities\":{\"tools\":{}},"
                "\"serverInfo\":{\"name\":\"swim-mcp\",\"version\":\"0.1.0\"}}");
        } else if (strcmp(method, "notifications/initialized") == 0) {
            // No response needed for notifications
        } else if (strcmp(method, "tools/list") == 0) {
            send_mcp_result(id_str, id_int, id_is_string, kToolsList);
        } else if (strcmp(method, "tools/call") == 0) {
            char *params = json_get_object(msg, "params");
            char *name = params ? json_get_string(params, "name") : NULL;
            char *arguments = params ? json_get_object(params, "arguments") : NULL;

            if (!name) {
                send_mcp_error(id_str, id_int, id_is_string,
                    -32602, "missing tool name");
            } else if (strcmp(name, "swim") != 0) {
                send_mcp_error(id_str, id_int, id_is_string,
                    -32602, "unknown tool");
            } else {
                // Single tool: extract method from arguments
                char *tool_method = arguments ? json_get_string(arguments, "method") : NULL;
                if (!tool_method) {
                    send_mcp_error(id_str, id_int, id_is_string,
                        -32602, "missing method parameter");
                    free(params); free(name); free(arguments);
                    free(method); free(id_str); free(msg);
                    continue;
                }
                char *result = handle_tool_call(tool_method, arguments ? arguments : "{}");

                // Check if this is binary content (image or resource)
                bool is_image = (strstr(result, "\"type\":\"image\"") != NULL);
                bool is_resource = (strstr(result, "\"type\":\"resource\"") != NULL);

                if (is_image || is_resource) {
                    // Return as MCP content directly
                    int buf_size = (int)strlen(result) + 256;
                    char *response = malloc(buf_size);
                    snprintf(response, buf_size,
                        "{\"content\":[%s]}", result);
                    send_mcp_result(id_str, id_int, id_is_string, response);
                    free(response);
                } else {
                    // Return as MCP text content — escape the result for JSON embedding
                    char *escaped = json_escape(result);
                    int buf_size = (int)strlen(escaped) + 256;
                    char *response = malloc(buf_size);
                    snprintf(response, buf_size,
                        "{\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}",
                        escaped);
                    send_mcp_result(id_str, id_int, id_is_string, response);
                    free(escaped);
                    free(response);
                }
                free(result);
                free(tool_method);
            }

            free(params);
            free(name);
            free(arguments);
        } else {
            if (id_str || id_int) {
                send_mcp_error(id_str, id_int, id_is_string,
                    -32601, "method not found");
            }
        }

        free(method);
        free(id_str);
        free(msg);
    }

    return 0;
}
