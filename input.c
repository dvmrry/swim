#include "input.h"
#include <stdlib.h>
#include <string.h>

// --- Key Trie ---

static void node_init(TrieNode *n) {
    memset(n, 0, sizeof(*n));
}

static TrieNode *node_find_child(TrieNode *n, char key) {
    for (int i = 0; i < n->child_count; i++) {
        if (n->children[i].key == key) return &n->children[i];
    }
    return NULL;
}

static TrieNode *node_add_child(TrieNode *n, char key) {
    if (n->child_count >= n->child_capacity) {
        n->child_capacity = n->child_capacity ? n->child_capacity * 2 : 4;
        n->children = realloc(n->children, n->child_capacity * sizeof(TrieNode));
    }
    TrieNode *child = &n->children[n->child_count++];
    node_init(child);
    child->key = key;
    return child;
}

static void node_free(TrieNode *n) {
    for (int i = 0; i < n->child_count; i++) {
        node_free(&n->children[i]);
    }
    free(n->children);
    free(n->action);
}

void keytrie_init(KeyTrie *t) {
    node_init(&t->root);
}

void keytrie_bind(KeyTrie *t, const char *keys, const char *action) {
    TrieNode *node = &t->root;
    for (int i = 0; keys[i]; i++) {
        TrieNode *child = node_find_child(node, keys[i]);
        if (!child) {
            child = node_add_child(node, keys[i]);
        }
        node = child;
    }
    free(node->action);
    node->action = strdup(action);
}

const char *keytrie_lookup(KeyTrie *t, const char *keys) {
    TrieNode *node = &t->root;
    for (int i = 0; keys[i]; i++) {
        TrieNode *child = node_find_child(node, keys[i]);
        if (!child) return NULL;
        node = child;
    }
    if (node->action) return node->action;
    if (node->child_count > 0) return "";  // prefix match
    return NULL;
}

void keytrie_free(KeyTrie *t) {
    node_free(&t->root);
}

// --- Mode Manager ---

void mode_init(ModeManager *m, ActionFn on_action, void *ctx) {
    memset(m, 0, sizeof(*m));
    m->mode = MODE_NORMAL;
    m->on_action = on_action;
    m->action_ctx = ctx;
    keytrie_init(&m->normal_keys);

    // Default normal mode bindings
    keytrie_bind(&m->normal_keys, "j",  "scroll-down");
    keytrie_bind(&m->normal_keys, "k",  "scroll-up");
    keytrie_bind(&m->normal_keys, "h",  "scroll-left");
    keytrie_bind(&m->normal_keys, "l",  "scroll-right");
    keytrie_bind(&m->normal_keys, "d",  "close-tab");
    keytrie_bind(&m->normal_keys, "u",  "undo-close-tab");
    keytrie_bind(&m->normal_keys, "o",  "command-open");
    keytrie_bind(&m->normal_keys, "O",  "command-open-current");
    keytrie_bind(&m->normal_keys, "t",  "command-tabopen");
    keytrie_bind(&m->normal_keys, "r",  "reload");
    keytrie_bind(&m->normal_keys, "H",  "back");
    keytrie_bind(&m->normal_keys, "L",  "forward");
    keytrie_bind(&m->normal_keys, "J",  "prev-tab");
    keytrie_bind(&m->normal_keys, "K",  "next-tab");
    keytrie_bind(&m->normal_keys, "G",  "scroll-bottom");
    keytrie_bind(&m->normal_keys, "gg", "scroll-top");
    keytrie_bind(&m->normal_keys, "yy", "yank-url");
    keytrie_bind(&m->normal_keys, "f",  "hint-follow");
    keytrie_bind(&m->normal_keys, "F",  "hint-tab");
    keytrie_bind(&m->normal_keys, "/",  "find");
    keytrie_bind(&m->normal_keys, "n",  "find-next");
    keytrie_bind(&m->normal_keys, "N",  "find-prev");
    keytrie_bind(&m->normal_keys, ":",  "enter-command");
}

void mode_set(ModeManager *m, Mode mode) {
    m->mode = mode;
    m->pending_len = 0;
    memset(m->pending_keys, 0, sizeof(m->pending_keys));
}

bool mode_handle_key(ModeManager *m, const char *key, unsigned int modifiers) {
    switch (m->mode) {
    case MODE_NORMAL: {
        // Ctrl-D / Ctrl-U for half page scroll
        if (modifiers & MOD_CTRL) {
            if (key[0] == '\x04') {  // Ctrl-D
                if (m->on_action) m->on_action("scroll-half-down", m->action_ctx);
                return true;
            }
            if (key[0] == '\x15') {  // Ctrl-U
                if (m->on_action) m->on_action("scroll-half-up", m->action_ctx);
                return true;
            }
            if (key[0] == '\x06') {  // Ctrl-F
                if (m->on_action) m->on_action("scroll-full-down", m->action_ctx);
                return true;
            }
            if (key[0] == '\x02') {  // Ctrl-B
                if (m->on_action) m->on_action("scroll-full-up", m->action_ctx);
                return true;
            }
        }

        // Accumulate in pending buffer
        if (m->pending_len < (int)sizeof(m->pending_keys) - 1) {
            m->pending_keys[m->pending_len++] = key[0];
            m->pending_keys[m->pending_len] = '\0';
        }

        const char *result = keytrie_lookup(&m->normal_keys, m->pending_keys);
        if (result == NULL) {
            // No match, reset
            m->pending_len = 0;
            memset(m->pending_keys, 0, sizeof(m->pending_keys));
            return false;
        }
        if (result[0] == '\0') {
            // Prefix match, wait for more keys
            return true;
        }
        // Complete match
        m->pending_len = 0;
        memset(m->pending_keys, 0, sizeof(m->pending_keys));
        if (m->on_action) m->on_action(result, m->action_ctx);
        return true;
    }

    case MODE_INSERT:
        // Escape returns to normal
        if (key[0] == '\x1b') {
            mode_set(m, MODE_NORMAL);
            if (m->on_action) m->on_action("mode-normal", m->action_ctx);
            return true;
        }
        return false;  // pass through to page

    case MODE_COMMAND:
        // Command bar handles its own keys via NSTextField
        // Escape cancels
        if (key[0] == '\x1b') {
            mode_set(m, MODE_NORMAL);
            if (m->on_action) m->on_action("mode-normal", m->action_ctx);
            return true;
        }
        return false;

    case MODE_PASSTHROUGH:
        // Ctrl-V escapes back to normal (Ctrl-V = 0x16)
        if (key[0] == '\x16' && (modifiers & MOD_CTRL)) {
            mode_set(m, MODE_NORMAL);
            if (m->on_action) m->on_action("mode-normal", m->action_ctx);
            return true;
        }
        return false;

    case MODE_HINT:
        if (key[0] == '\x1b') {
            if (m->on_action) m->on_action("hint-cancel", m->action_ctx);
            mode_set(m, MODE_NORMAL);
            if (m->on_action) m->on_action("mode-normal", m->action_ctx);
            return true;
        }
        // Accumulate hint characters and send filter action
        if (key[0] >= 'a' && key[0] <= 'z') {
            if (m->pending_len < (int)sizeof(m->pending_keys) - 1) {
                m->pending_keys[m->pending_len++] = key[0];
                m->pending_keys[m->pending_len] = '\0';
            }
            if (m->on_action) m->on_action("hint-filter", m->action_ctx);
            return true;
        }
        return true;  // consume everything in hint mode
    }
    return false;
}

void mode_free(ModeManager *m) {
    keytrie_free(&m->normal_keys);
}
