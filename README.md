# Visualizer

A macOS audio visualizer that listens to your system output (or just Spotify) and renders beat-synced Metal visuals: Silk, Nebula Tunnel, Ribbons, Aurora, Contours, Halo, Ridgeline, Bokeh, Chrome, Kaleidoscope, Keys, Bars and Scope.

Requires macOS 14+. Audio is captured with ScreenCaptureKit, so the first launch asks for **Screen & System Audio Recording** permission.

## Install

Download `Visualizer-macOS.zip` from the [latest release](../../releases/latest), unzip, and move `Visualizer.app` to Applications. Release builds are ad-hoc signed (not notarized), so on first launch right-click the app → **Open**, or run `xattr -dr com.apple.quarantine Visualizer.app`.

## Build

```sh
./build.sh run
```

Signs with your Apple Development identity if one is in the keychain (keeps the permission grant across rebuilds); otherwise ad-hoc.

## Keys

| Key | Action |
| --- | --- |
| `M` / `Space` / `→`, `←` | Next / previous mode |
| `1`–`9`, `0` | Jump to mode 1–10 |
| `F` / `Return`, `Esc` | Enter / exit fullscreen |
| `P` | Cycle palette (album art when Spotify is playing) |
| `S` | Switch source: system audio / Spotify |
| `T` | Show track info |
| `B` | Show detected BPM |
| `[` / `]` | Shift beat timing ±10 ms |
