#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

ARCH="$(uname -m)"
swiftc \
  -target "${ARCH}-apple-macosx14.0" \
  "$PROJECT_ROOT"/Sources/MACCore/*.swift \
  "$PROJECT_ROOT"/Tests/MACAppTestMain.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework IOKit \
  -o "$BUILD_DIR/MACAppTests"

MAC_DISABLE_AUTO_LAUNCH_AGENT=1 "$BUILD_DIR/MACAppTests"
