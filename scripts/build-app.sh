#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/mac.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
RUNTIME_DIR="$RESOURCES_DIR/runtime"

rm -rf "$PROJECT_ROOT/MAC.app" "$APP_PATH" "$PROJECT_ROOT/.build"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$RUNTIME_DIR/src"

if [ -d "$PROJECT_ROOT/Resources" ]; then
  cp -R "$PROJECT_ROOT"/Resources/* "$RESOURCES_DIR/" 2>/dev/null || true
fi

# Bundle Node.js bot runtime inside mac.app so the app is 100% standalone
cp "$PROJECT_ROOT"/src/*.mjs "$RUNTIME_DIR/src/"
cp "$PROJECT_ROOT/package.json" "$RUNTIME_DIR/package.json"

ARCH="$(uname -m)"
swiftc -O \
  -target "${ARCH}-apple-macosx14.0" \
  "$PROJECT_ROOT"/Sources/MACCore/*.swift \
  "$PROJECT_ROOT"/Sources/MACApp/main.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework IOKit \
  -o "$MACOS_DIR/MAC"

chmod +x "$MACOS_DIR/MAC"

PROJECT_ROOT_KEY=""
if [ "${MAC_PORTABLE_BUILD:-0}" != "1" ]; then
  PROJECT_ROOT_KEY="  <key>MACDefaultProjectRoot</key>
  <string>${PROJECT_ROOT}</string>"
fi

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>mac</string>
  <key>CFBundleDisplayName</key>
  <string>mac</string>
  <key>CFBundleIdentifier</key>
  <string>com.domonk.mac</string>
  <key>CFBundleVersion</key>
  <string>3.1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>3.1.0</string>
  <key>CFBundleExecutable</key>
  <string>MAC</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
${PROJECT_ROOT_KEY}
</dict>
</plist>
EOF

xattr -cr "$APP_PATH" 2>/dev/null || true
codesign --force --deep --sign - "$APP_PATH"

echo "Built standalone native macOS menu bar app: $APP_PATH"
