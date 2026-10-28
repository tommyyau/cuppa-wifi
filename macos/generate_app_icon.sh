#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d -t wifi-autologin-app-icon)"
trap 'rm -rf "$WORK_DIR"' EXIT

swiftc "$ROOT/macos/AppIcon.swift" -o "$WORK_DIR/render-icon"
"$WORK_DIR/render-icon" "$WORK_DIR/AppIcon.iconset"
iconutil --convert icns "$WORK_DIR/AppIcon.iconset" \
  --output "$ROOT/macos/Resources/AppIcon.icns"
echo "$ROOT/macos/Resources/AppIcon.icns"
