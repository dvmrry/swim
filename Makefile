CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra -Wpedantic -std=c17
FRAMEWORKS = -framework Cocoa -framework WebKit -framework QuartzCore

SRC_C = browser.c input.c commands.c storage.c config.c userscript.c
SRC_M = main.m ui.m
SRC = $(SRC_C) $(SRC_M)

swim: $(SRC) browser.h input.h commands.h ui.h storage.h config.h userscript.h Info.plist
	$(CC) $(CFLAGS) $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist $(SRC) -o swim

test-ui: $(SRC) test_server.m test_server.h browser.h input.h commands.h ui.h storage.h config.h userscript.h Info.plist
	$(CC) $(CFLAGS) -DSWIM_TEST $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist $(SRC) test_server.m -o swim-test

clean:
	rm -f swim swim-test

.PHONY: clean test-ui
