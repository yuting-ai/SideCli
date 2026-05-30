# SideCli

SideCli is a lightweight macOS terminal focused on a sidebar workflow:

- Auto-hide on the screen edge to save space
- Pop out instantly when needed
- Native-like terminal interaction and shortcuts
- Minimal footprint (targeting a lightweight app package)

## Features

- Tabs and split panes
- Configurable global shortcut to show/hide
- Dark/light theme and font size settings
- First-run onboarding and quick tour
- Built-in About section with third-party license notice

## Demo

[Watch demo on YouTube](https://www.youtube.com/watch?v=Bg47zOdqfzs)

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

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — MIT License

## Download

[![Direct DMG (latest)](./download-button.svg)](https://github.com/yuting-ai/SideCli/releases/latest/download/SideCli.dmg)

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
