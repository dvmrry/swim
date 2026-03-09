#ifndef SWIM_FOCUS_H
#define SWIM_FOCUS_H

#include "theme.h"

// Load focus.js template, substitute theme colors, return malloc'd JS string.
// Caller must free the result. Returns NULL on failure.
char *focus_build_js(SwimTheme *theme, const char *scripts_dir);

// Write default focus.js to scripts_dir if it doesn't exist.
void focus_create_default(const char *scripts_dir);

#endif
