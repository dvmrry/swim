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

// Starts HTTP server in a background thread.
// addr: port number string ("9111") for TCP, or file path for Unix socket.
// NULL defaults to ~/.config/swim/swim.sock
// ctx must remain valid for the lifetime of the server.
void serve_start(const char *addr, ServeContext *ctx);

// Sidebar MCP bridge — implemented in main.m, called from serve.m
void sidebar_clear_pending(void);
void sidebar_post_response(const char *text, bool is_system);

#endif
