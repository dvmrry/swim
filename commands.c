#include "commands.h"
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#define INITIAL_CAP 16

void registry_init(CommandRegistry *r, void *ctx) {
    memset(r, 0, sizeof(*r));
    r->capacity = INITIAL_CAP;
    r->commands = calloc(INITIAL_CAP, sizeof(Command));
    r->ctx = ctx;
}

void registry_add(CommandRegistry *r, const char *name, const char *alias,
                  CommandFn fn, const char *description) {
    if (r->count >= r->capacity) {
        r->capacity *= 2;
        r->commands = realloc(r->commands, r->capacity * sizeof(Command));
    }
    Command *c = &r->commands[r->count++];
    c->name = strdup(name);
    c->alias = alias ? strdup(alias) : NULL;
    c->fn = fn;
    c->description = description ? strdup(description) : NULL;
}

static Command *find_command(CommandRegistry *r, const char *name) {
    for (int i = 0; i < r->count; i++) {
        if (strcmp(r->commands[i].name, name) == 0) return &r->commands[i];
        if (r->commands[i].alias && strcmp(r->commands[i].alias, name) == 0)
            return &r->commands[i];
    }
    return NULL;
}

bool registry_exec(CommandRegistry *r, const char *input) {
    if (!input || !input[0]) return false;

    // Skip leading whitespace
    while (*input == ' ') input++;

    // Extract command name
    char name[64];
    int i = 0;
    while (input[i] && input[i] != ' ' && i < 63) {
        name[i] = input[i];
        i++;
    }
    name[i] = '\0';

    // Find args (skip space after command name)
    const char *args = input[i] ? input + i + 1 : "";

    Command *cmd = find_command(r, name);
    if (!cmd) return false;

    cmd->fn(args, r->ctx);
    return true;
}

const char *registry_complete(CommandRegistry *r, const char *prefix) {
    if (!prefix || !prefix[0]) return NULL;
    int len = strlen(prefix);
    for (int i = 0; i < r->count; i++) {
        if (strncmp(r->commands[i].name, prefix, len) == 0)
            return r->commands[i].name;
    }
    return NULL;
}

void registry_free(CommandRegistry *r) {
    for (int i = 0; i < r->count; i++) {
        free(r->commands[i].name);
        free(r->commands[i].alias);
        free(r->commands[i].description);
    }
    free(r->commands);
    memset(r, 0, sizeof(*r));
}
