#ifndef SWIM_COMMANDS_H
#define SWIM_COMMANDS_H

#include <stdbool.h>

typedef void (*CommandFn)(const char *args, void *ctx);

typedef struct Command {
    char *name;
    char *alias;
    CommandFn fn;
    char *description;
} Command;

typedef struct CommandRegistry {
    Command *commands;
    int count;
    int capacity;
    void *ctx;  // passed to all command functions
} CommandRegistry;

void registry_init(CommandRegistry *r, void *ctx);
void registry_add(CommandRegistry *r, const char *name, const char *alias,
                  CommandFn fn, const char *description);
// Execute a command string like "open https://example.com"
bool registry_exec(CommandRegistry *r, const char *input);
// Tab completion: returns matching command name or NULL
const char *registry_complete(CommandRegistry *r, const char *prefix);
void registry_free(CommandRegistry *r);

#endif
