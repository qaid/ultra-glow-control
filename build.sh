#!/bin/bash
# Builds "Litra Glow.app": a menubar app controlling a Logitech Litra Glow USB light via IOKit HID.
# Plain swiftc, no Xcode project. `./build.sh --install` also copies it to ~/Applications.
set -e
cd "$(dirname "$0")"

APP="Litra Glow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc LitraGlow.swift \
  -parse-as-library \
  -framework Cocoa -framework SwiftUI -framework IOKit -framework ServiceManagement \
  -target arm64-apple-macos13.0 \
  -O \
  -o "$APP/Contents/MacOS/Litra Glow"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>design.constellation.litra-glow</string>
    <key>CFBundleName</key><string>Litra Glow</string>
    <key>CFBundleExecutable</key><string>Litra Glow</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS will run it (and so SMAppService login-item registration behaves).
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Built: $(pwd)/$APP"

if [ "$1" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP"
  cp -R "$APP" "$HOME/Applications/$APP"
  codesign --force --deep -s - "$HOME/Applications/$APP" 2>/dev/null || true
  echo "Installed: $HOME/Applications/$APP"
fi
