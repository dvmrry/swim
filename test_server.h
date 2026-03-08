#ifndef SWIM_TEST_SERVER_H
#define SWIM_TEST_SERVER_H

#ifdef SWIM_TEST

#include "ui.h"
#include "browser.h"
#include "input.h"
#include "commands.h"

typedef struct TestContext {
    SwimUI *ui;
    Browser *browser;
    ModeManager *mode;
    CommandRegistry *commands;
    void (*handle_action)(const char *action, void *ctx);
    void *action_ctx;
} TestContext;

// Starts HTTP server on given port in a background thread.
// ctx must remain valid for the lifetime of the server (stack-allocated in main is fine
// since main never returns — NSApp run loops forever).
void test_server_start(int port, TestContext *ctx);

#endif // SWIM_TEST
#endif // SWIM_TEST_SERVER_H
