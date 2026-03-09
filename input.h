#ifndef SWIM_INPUT_H
#define SWIM_INPUT_H

#include <stdbool.h>

typedef enum {
    MODE_NORMAL,
    MODE_INSERT,
    MODE_COMMAND,
    MODE_HINT,
    MODE_PASSTHROUGH,
} Mode;

// Action callback: receives action name and user context
typedef void (*ActionFn)(const char *action, void *ctx);

// --- Key Trie ---

typedef struct TrieNode {
    char key;
    struct TrieNode *children;
    int child_count;
    int child_capacity;
    char *action;  // non-NULL if this node completes a binding
} TrieNode;

typedef struct KeyTrie {
    TrieNode root;
} KeyTrie;

void keytrie_init(KeyTrie *t);
void keytrie_bind(KeyTrie *t, const char *keys, const char *action);
// Returns: action string if complete, "" if prefix (partial match), NULL if no match
const char *keytrie_lookup(KeyTrie *t, const char *keys);
void keytrie_free(KeyTrie *t);

// --- Mode Manager ---

typedef struct ModeManager {
    Mode mode;
    char pending_keys[32];
    int pending_len;
    int count;              // count prefix (e.g., 5 in 5j), 0 = no count
    char last_action[64];   // for . repeat
    KeyTrie normal_keys;
    ActionFn on_action;
    void *action_ctx;
} ModeManager;

void mode_init(ModeManager *m, ActionFn on_action, void *ctx);
void mode_set(ModeManager *m, Mode mode);
// Returns true if the key was consumed (not passed to the page)
bool mode_handle_key(ModeManager *m, const char *key, unsigned int modifiers);
void mode_free(ModeManager *m);

// Modifier flags (match NSEvent modifier flags >> 16)
#define MOD_CTRL  (1 << 0)
#define MOD_SHIFT (1 << 1)
#define MOD_ALT   (1 << 2)
#define MOD_CMD   (1 << 3)

#endif
