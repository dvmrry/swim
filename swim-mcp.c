#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// --- Configuration ---

static int g_port = 9111;

// --- Simple JSON helpers (no dependencies) ---

// Find a string value for a key in a JSON object (simple flat parser)
// Returns malloc'd string or NULL. Caller must free.
static char *json_get_string(const char *json, const char *key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return NULL;
    p += strlen(search);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (*p != '"') return NULL;
    p++;
    const char *end = p;
    while (*end && *end != '"') {
        if (*end == '\\') end++;
        end++;
    }
    int len = (int)(end - p);
    char *result = malloc(len + 1);
    memcpy(result, p, len);
    result[len] = '\0';
    return result;
}

// Find an integer value for a key
static bool json_get_int(const char *json, const char *key, int *out) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return false;
    p += strlen(search);
    while (*p && (*p == ' ' || *p == ':' || *p == '\t')) p++;
    if (*p != '-' && (*p < '0' || *p > '9')) return false;
    *out = atoi(p);
    return true;
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

// --- MCP Protocol ---

static void send_mcp(const char *json) {
    int len = (int)strlen(json);
    printf("Content-Length: %d\r\n\r\n%s", len, json);
    fflush(stdout);
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
    "{\"name\":\"navigate\","
    "\"description\":\"Navigate to a URL in the active tab\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"URL to navigate to\"}},"
    "\"required\":[\"url\"]}},"

    "{\"name\":\"screenshot\","
    "\"description\":\"Capture a PNG screenshot of the current page\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"

    "{\"name\":\"extract\","
    "\"description\":\"Extract page content as markdown with links and metadata\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"

    "{\"name\":\"execute\","
    "\"description\":\"Run a swim command (e.g. 'tabopen url', 'bookmark', 'session save name')\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Command to execute\"}},"
    "\"required\":[\"command\"]}},"

    "{\"name\":\"action\","
    "\"description\":\"Trigger a keybinding action (e.g. 'scroll-down', 'hint-follow', 'reload')\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"action\":{\"type\":\"string\",\"description\":\"Action name\"},"
    "\"count\":{\"type\":\"integer\",\"description\":\"Repeat count\"}},"
    "\"required\":[\"action\"]}},"

    "{\"name\":\"state\","
    "\"description\":\"Get browser state: mode, URL, title, tab list\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"

    "{\"name\":\"click\","
    "\"description\":\"Click an element by CSS selector or text content\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{"
    "\"selector\":{\"type\":\"string\",\"description\":\"CSS selector\"},"
    "\"text\":{\"type\":\"string\",\"description\":\"Text content to match\"}}}},"

    "{\"name\":\"key\","
    "\"description\":\"Send a keypress (e.g. 'j', 'Escape', 'Ctrl-D')\","
    "\"inputSchema\":{\"type\":\"object\","
    "\"properties\":{\"key\":{\"type\":\"string\",\"description\":\"Key to send\"}},"
    "\"required\":[\"key\"]}}"
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

    if (strcmp(name, "extract") == 0) {
        char *resp = http_get("/extract");
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

    return strdup("{\"error\":\"unknown tool\"}");
}

// --- Read MCP message from stdin ---

static char *read_mcp_message(void) {
    // Read Content-Length header
    char line[256];
    int content_length = 0;

    while (fgets(line, sizeof(line), stdin)) {
        if (strncmp(line, "Content-Length:", 15) == 0) {
            content_length = atoi(line + 15);
        }
        // Empty line = end of headers
        if (strcmp(line, "\r\n") == 0 || strcmp(line, "\n") == 0) break;
    }

    if (content_length <= 0 || content_length > 10485760) return NULL;

    char *body = malloc(content_length + 1);
    int total = 0;
    while (total < content_length) {
        int n = (int)fread(body + total, 1, content_length - total, stdin);
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

    // Log to stderr (stdout is MCP protocol)
    fprintf(stderr, "swim-mcp: connecting to swim on port %d\n", g_port);

    // MCP message loop
    while (1) {
        char *msg = read_mcp_message();
        if (!msg) break;

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
                "{\"protocolVersion\":\"2024-11-05\","
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
            } else {
                char *result = handle_tool_call(name, arguments ? arguments : "{}");

                // Check if this is a screenshot (image content type)
                bool is_image = (strstr(result, "\"type\":\"image\"") != NULL);

                if (is_image) {
                    // Return as MCP image content directly
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
