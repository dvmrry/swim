#ifndef SWIM_SERVE_H
#define SWIM_SERVE_H

#include "ui.h"
#include "browser.h"
#include "input.h"
#include "commands.h"

typedef struct ServeContext {
    SwimUI *ui;
    Browser *browser;
    ModeManager *mode;
    CommandRegistry *commands;
    void (*handle_action)(const char *action, void *ctx);
    void *action_ctx;
} ServeContext;

// Starts HTTP server on given port in a background thread.
// ctx must remain valid for the lifetime of the server.
void serve_start(int port, ServeContext *ctx);

#endif
