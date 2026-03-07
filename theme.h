#ifndef SWIM_THEME_H
#define SWIM_THEME_H

#include <stdbool.h>

typedef struct {
    float r, g, b;
} ThemeColor;

typedef struct {
    char name[64];
    ThemeColor bg;
    ThemeColor status_bg;
    ThemeColor fg;
    ThemeColor fg_dim;
    ThemeColor normal;
    ThemeColor insert;
    ThemeColor command;
    ThemeColor hint;
    ThemeColor passthrough;
    ThemeColor accent;
} SwimTheme;

void theme_init_defaults(SwimTheme *t);
bool theme_load(SwimTheme *t, const char *filepath);
void theme_create_defaults(const char *dir_path);

#endif
