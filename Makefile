CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra -Wpedantic -std=c17
FRAMEWORKS = -framework Cocoa -framework WebKit

SRC_C = browser.c input.c commands.c storage.c config.c
SRC_M = main.m ui.m
SRC = $(SRC_C) $(SRC_M)

swim: $(SRC) browser.h input.h commands.h ui.h storage.h config.h
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(SRC) -o swim

clean:
	rm -f swim

.PHONY: clean
