# SideCli

SideCli is a lightweight macOS terminal that lives on the edge of your screen:

- Snaps to the left or right screen edge and auto-hides to save space
- Slides out when the mouse reaches the edge, or with a global shortcut
- Drag it away from the edge and it is a regular window instead
- Native terminal rendering powered by SwiftTerm
- Shows in the menu bar and the Dock

<p align="center">
  <img src="docs/screenshots/sidecli-dark.png" alt="SideCli in the dark theme: one tab split into three panes running git log and ls, with a second tab open; the panes that don't have focus are dimmed" width="49%">
  <img src="docs/screenshots/sidecli-light.png" alt="SideCli in the light theme: a tab split top and bottom; the focused pane stays bright and the other is dimmed" width="49%">
</p>

## Features

- Two modes: docked to a screen edge it floats above other apps and auto-hides; dragged away from the edge (or filling the screen) it is a regular window that other apps can cover
- Tabs, each with its own split panes: split top/bottom or left/right and nest freely
- `⌘D` picks the split direction with more room; panes keep a usable minimum size
- Zoom a pane to fill the panel, equalize panes, move focus between panes from the keyboard
- The panel widens automatically for left/right splits and shrinks back when they close
- Tabs, panes, ratios and working directories are saved continuously and restored on launch, together with the window's mode, position and size
- Window buttons like any Mac window: hide, minimize to the Dock, fill the screen; double-click the toolbar to fill the screen too
- Asks before closing a pane or tab, or quitting, while a program is still running in it; `exit` closes the pane, and a shell that exits with an error can be restarted with Return
- Full-screen programs (vim, AI coding CLIs, …) redraw correctly after every split, zoom and resize
- Input methods (Chinese, Japanese, Korean, …) show the text being composed at the cursor
- Paste a screenshot or a file from Finder to insert its path
- A menu bar listing every command and its shortcut
- Configurable global shortcut, dark/light theme, font size, English/Chinese interface
- First-run welcome screen and quick tour
- No analytics or usage data collection

## Keyboard Shortcuts

| Action | Shortcut |
| --- | --- |
| New tab | `⌘T` |
| Close pane (closes the tab when it is the last pane) | `⌘W` |
| Split, automatic direction | `⌘D` |
| Split the other way | `⌘⇧D` |
| Zoom / restore pane | `⌘⇧↩` |
| Move between panes | `⌘⌥←` `⌘⌥→` `⌘⌥↑` `⌘⌥↓` |
| Go to tab 1–8 / last tab | `⌘1` … `⌘8` / `⌘9` |
| Next / previous tab | `⌘⇧]` / `⌘⇧[` |
| Clear screen and scrollback | `⌘K` |
| Font size / default size | `⌘=` / `⌘-` / `⌘0` |
| Settings | `⌘,` |
| Hide / minimize panel | `⌘H` / `⌘M` |
| Show / hide panel (default, configurable) | ``⌘` `` |

## Requirements

- macOS 14.6 or later (Apple Silicon or Intel)
- Xcode 26 or later to build

## Build and Run

1. Open `SideCli/SideCli.xcodeproj` in Xcode.
2. Select the `SideCli` scheme.
3. Build and run.

Or with the command line:

```bash
xcodebuild -project "SideCli/SideCli.xcodeproj" -scheme "SideCli" -configuration Debug build
```

## Repository Layout

- `SideCli/` — the Xcode project and app sources
- `branding/` — SVG sources for the app, menu bar and logo icons, plus `export-icons.swift`, which regenerates every icon asset:

  ```bash
  swift branding/export-icons.swift
  ```

## Third-Party Software

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — MIT License

## Download

[![Direct DMG (latest)](./download-button.svg)](https://github.com/yuting-ai/SideCli/releases/latest/download/SideCli.dmg)

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
