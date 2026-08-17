# AGENTS.md

Guidance for any AI agent working in this repo (Claude Code, Codex, others). Single source of truth: `CLAUDE.md` imports this file, so edit here, not there.

## What this project is

`ultra-glow-control` is a macOS menu-bar app that controls a **Logitech Litra Glow** USB light (power, brightness, color temperature) using only open-source code: no Logitech software, no account. The Litra is a vendor-defined HID device, so the app talks to it directly over IOKit HID using the reverse-engineered 20-byte report protocol documented by [timrogers/litra](https://github.com/timrogers/litra) and [kharyam/litra-driver](https://github.com/kharyam/litra-driver).

One deliverable:
- **Litra Glow.app** — a SwiftUI/AppKit menu-bar agent app, `LitraGlow.swift`, built by `./build.sh`.

See `README.md` for the feature list and usage.

## Hard rules

- **No network calls, ever.** The point is a private, local-only control panel. Nothing may phone home or require an account.
- **Commit and push only when the user asks.** Work is local-first; the user reviews before every commit.

## Layout

```
LitraGlow.swift   the whole app (HID layer + model + SwiftUI panel)
build.sh          swiftc build -> "Litra Glow.app"  (--install copies to ~/Applications)
```

## Protocol notes (the part that's easy to get wrong)

- Match VID `0x046d` + PID `0xc900`, then open the interface advertising usagePage `0xff43` (checked across the device's usage *pairs*, like node-hid — not just the primary usage page, since 0xff43 may be a secondary collection). Only that interface accepts light commands. There's a fallback to the sole matching device if no 0xff43 interface enumerates.
- Commands are 20-byte output reports, report id `0x11`, feature index `0x04` (Beam LX would be `0x06`), right-padded with `0x00`:
  - power: `11 ff 04 1c 01`/`00`; brightness: `11 ff 04 4c <hi> <lo>` (Lumen 20-250); temperature: `11 ff 04 9c <hi> <lo>` (Kelvin, multiples of 100, 2700-6500).
- **SetReport framing:** send the full 20-byte buffer (leading `0x11` kept) with `reportID = 0x11` — this mirrors hidapi's verified macOS `set_report` (it strips the leading byte only when it's `0x00`). Fallback if a device no-ops: `reportID 0x11` with `bytes[1...]`.
- If commands silently do nothing, first suspect is another app (**Logi Options+ / G HUB / Logitech**) holding the device — a separate cause from framing.

## Conventions

- **The app is one file** (`LitraGlow.swift`). To add a settings toggle, follow the `launchAtLogin` pattern: a `@Published` model property + a setter + a `Toggle` using `ApertureToggleStyle`. State whose truth lives outside the app (login-item status) reads its real source on `.onAppear`, not UserDefaults.
- **Visual direction is "Aperture":** warm charcoal ground with brass/amber accents, shared verbatim with the sibling `obsbot-control` menu-bar app so the two panels read as one family. Keep new UI within the `Aperture.*` palette and reuse `ApertureSlider` / `ApertureToggleStyle`.
- Slider writes are throttled (~1 report / 60ms) with a trailing send; HID++ drops flooded reports during a drag. Keep that when adding continuous controls.

## Building

- `./build.sh` (needs Xcode command-line tools; no Xcode project). `--install` also copies to `~/Applications`. Target `arm64-apple-macos13.0`, bundle id `design.constellation.litra-glow`, `LSUIElement` agent app.
