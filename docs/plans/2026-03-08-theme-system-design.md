# Theme System — Design

**Goal:** Load browser chrome colors from theme files in `~/.config/swim/themes/`, ship Tokyo Night and Kanagawa as defaults.

## File Format

Simple key-value, `#hex` colors, `#` comments:

```
# Tokyo Night
bg = #1a1b26
status-bg = #16161e
fg = #c0caf5
fg-dim = #565f89
normal = #9ece6a
insert = #7aa2f7
command = #e0af68
hint = #ff9e64
passthrough = #bb9af7
accent = #7aa2f7
```

10 color slots. Missing keys fall back to current hardcoded values.

## Architecture

- New: `theme.c` / `theme.h` — parser, hex-to-RGB conversion, defaults
- `config.toml`: `theme = "tokyonight"` selects `~/.config/swim/themes/tokyonight.theme`
- `ui.m` — reads theme colors at UI creation instead of hardcoded values
- `main.m` — loads theme at startup, passes to UI
- First run: create `~/.config/swim/themes/` with `tokyonight.theme` and `kanagawa.theme`

## Color Slots

| Slot | Elements |
|------|----------|
| `bg` | Window bg, tab bar bg |
| `status-bg` | Status bar bg, command bar bg |
| `fg` | Active tab text, URL text |
| `fg-dim` | Inactive tab text, find bar label |
| `normal` | Normal mode badge, active tab indicator |
| `insert` | Insert mode badge |
| `command` | Command mode badge, colon prefix, pending keys bg |
| `hint` | Hint mode badge |
| `passthrough` | Passthrough mode badge |
| `accent` | Progress text, active tab border |

Mode badge text color: derived as dark (`bg`) on the badge color.

## Dark Mode Userscript

Separate concern — ships as `dark-mode.js.disabled` in `~/.config/swim/scripts/`. CSS `filter: invert(1) hue-rotate(180deg)` with image/video re-invert. Rename to `.js` to enable. Independent of chrome theme for now.

## Config Integration

- `appearance.theme` in config.toml (field already exists)
- Theme loaded at startup, applied once
- Changing theme requires restart
