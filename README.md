# Litra Glow control

A small macOS menu-bar app to control a **Logitech Litra Glow** USB light: power, brightness, and color temperature, plus quick presets. Local-only, no Logitech software or account. Talks to the light directly over IOKit HID.

The panel shares its visual language ("Aperture" — warm charcoal with amber accents) with the sibling `obsbot-control` app.

## Features

- **Power** on/off toggle.
- **Brightness** slider (0-100%, mapped to the Glow's 20-250 lumen range).
- **Temperature** slider (2700-6500K, warm→cool track).
- **Presets:** Warm (2700K / 60%), Bright (6500K / 100%), Video call (4500K / 80%).
- **Launch at login** (via `SMAppService`).
- Remembers your last settings and re-applies them whenever the light reconnects.

## Build & install

```bash
./build.sh            # builds "Litra Glow.app" in this folder
./build.sh --install  # also copies it to ~/Applications
```

Needs the Xcode command-line tools (`xcode-select --install`). No Xcode project, no dependencies. Builds for `arm64-apple-macos13.0`.

Launch it from `~/Applications` (or double-click the built `.app`). It lives in the menu bar with no Dock icon; click the lightbulb icon to open the panel.

## Troubleshooting

- **No light detected / controls do nothing:** quit any Logitech software holding the device — **Logi Options+**, **G HUB**, or the **Logitech** desktop app — then reopen the panel.
- **Only a Litra Glow is supported.** Beam / Beam LX use different product IDs and (for the LX) a different feature index; see `AGENTS.md` for the protocol details if you want to extend it.

## How it works

The Litra Glow is a vendor-defined HID device (VID `046d` / PID `c900`). Control is via 20-byte HID output reports on the `0xff43` usage-page interface. Protocol credit: [timrogers/litra](https://github.com/timrogers/litra) and [kharyam/litra-driver](https://github.com/kharyam/litra-driver). Full byte-level notes live in `AGENTS.md`.
