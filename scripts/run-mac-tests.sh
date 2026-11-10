#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Embed LSUIElement=true directly into the test binary so macOS LaunchServices / Dock
# treats MACAppTests strictly as an invisible UIElement helper (never shown in Dock or Recents).
cat > "$BUILD_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.domonk.mac.tests</string>
  <key>CFBundleName</key>
  <string>MACAppTests</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

ARCH="$(uname -m)"
swiftc \
  -target "${ARCH}-apple-macosx14.0" \
  "$PROJECT_ROOT"/Sources/MACCore/*.swift \
  "$PROJECT_ROOT"/Tests/MACAppTestMain.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework IOKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$BUILD_DIR/Info.plist" \
  -o "$BUILD_DIR/MACAppTests"

MAC_DISABLE_AUTO_LAUNCH_AGENT=1 MAC_HEADLESS_TEST=1 "$BUILD_DIR/MACAppTests"
