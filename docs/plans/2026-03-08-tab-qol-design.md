# Tab QoL Improvements — Design

**Goal:** Add standard vi-mode browser tab management: Ngt jump, tab move, buffer list, tabclose N, tabonly.

## 1. `Ngt` — Jump to Tab by Number
Count prefix + `gt` switches to tab N. `1gt` = first, `5gt` = last if N > count. `gt` alone = next tab.

## 2. `<<` / `>>` — Move Tab Left/Right
Swaps active tab position. Wraps at edges. Needs browser_move_tab + ui_move_tab.

## 3. `:tabs` — List Open Tabs
Status message showing numbered tabs. Active tab marked with `*`. Truncated to fit.

## 4. `:tabclose N` — Close Tab by Number
Close specific tab without switching. No args = close current. Last tab = quit.

## 5. `:tabonly` — Close All But Current
Closes all other tabs. Adds closed URLs to undo stack.

## Testability
All drivable via test server batch endpoint + /state verification.
