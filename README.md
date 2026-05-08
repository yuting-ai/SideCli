# SideCli

SideCli is a lightweight macOS terminal focused on a sidebar workflow:

- Auto-hide on the screen edge to save space
- Pop out instantly when needed
- Native-like terminal interaction and shortcuts
- Minimal footprint (targeting a lightweight app package)

## Download

[![Latest Release](https://img.shields.io/github/v/release/yuting-ai/SideCli?display_name=tag&label=Latest%20Release)](https://github.com/yuting-ai/SideCli/releases/latest)
[![GitHub Downloads (all assets, latest release)](https://img.shields.io/github/downloads/yuting-ai/SideCli/latest/total?label=Latest%20Downloads)](https://github.com/yuting-ai/SideCli/releases/latest)

- Official website: [sidecli.com](https://sidecli.com)
- Direct DMG (latest): [SideCli.dmg](https://github.com/yuting-ai/SideCli/releases/latest/download/SideCli.dmg)
- Release page (all assets): [github.com/yuting-ai/SideCli/releases/latest](https://github.com/yuting-ai/SideCli/releases/latest)
- China mirror: add your domestic download URL here (recommended for faster access in mainland China)

## Features

- Tabs and split panes
- Configurable global shortcut to show/hide
- Dark/light theme and font size settings
- First-run onboarding and quick tour
- Built-in About section with third-party license notice

## Requirements

- macOS (Apple Silicon or Intel)
- Xcode 15+ (recommended)

## Build and Run

1. Open `SideCli.xcodeproj` in Xcode.
2. Select the `SideCli` scheme.
3. Build and run.

Or with command line:

```bash
xcodebuild -project "SideCli.xcodeproj" -scheme "SideCli" -configuration Debug build
```

## Open Source Notes

- This repository excludes user-local Xcode state (`xcuserdata`) and common local artifacts.
- Analytics/telemetry runtime calls are removed in this open-source copy.

## Third-Party Software

- [xterm.js](https://xtermjs.org/) — MIT License

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
