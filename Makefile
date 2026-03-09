CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra -Wpedantic -std=c17
FRAMEWORKS = -framework Cocoa -framework WebKit -framework QuartzCore -framework Network

SRC_C = browser.c input.c commands.c storage.c config.c userscript.c theme.c focus.c
SRC_M = main.m ui.m serve.m
SRC = $(SRC_C) $(SRC_M)
HEADERS = browser.h input.h commands.h ui.h storage.h config.h userscript.h theme.h focus.h serve.h

all: swim swim-mcp

swim: $(SRC) $(HEADERS) focus_js.inc extract_js.inc Info.plist
	$(CC) $(CFLAGS) $(FRAMEWORKS) -sectcreate __TEXT __info_plist Info.plist $(SRC) -o swim

swim-mcp: swim-mcp.c
	$(CC) -Wall -Wextra -Wpedantic -std=c17 swim-mcp.c -o swim-mcp

# Convert focus.js to a C string literal for embedding
focus_js.inc: js/focus.js
	@echo "Generating focus_js.inc"
	@sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$$/\\n"/' js/focus.js > focus_js.inc

extract_js.inc: js/extract.js
	@echo "Generating extract_js.inc"
	@sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$$/\\n"/' js/extract.js > extract_js.inc

clean:
	rm -f swim swim-mcp focus_js.inc extract_js.inc

.PHONY: clean all
