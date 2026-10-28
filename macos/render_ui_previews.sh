#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT/macos/CuppaAutologinApp" --product CuppaRuntime
RUNTIME="$(swift build --package-path "$ROOT/macos/CuppaAutologinApp" --show-bin-path)"
SOURCE="$ROOT/macos/CuppaAutologinApp/Sources/CuppaAutologin"
PREVIEW="$ROOT/macos/CuppaAutologinApp/Tests/VisualPreview.swift"
OUTPUT_DIR="${1:-/tmp/wifi-autologin-ui-previews}"
BINARY="$(mktemp -t wifi-autologin-ui-preview)"
trap 'rm -f "$BINARY"' EXIT

sources=()
while IFS= read -r source; do
  case "$(basename "$source")" in
    CuppaAutologinApp.swift) ;;
    *) sources+=("$source") ;;
  esac
done < <(find "$SOURCE" -maxdepth 1 -name '*.swift' -print | sort)

swiftc \
  -I "$RUNTIME" -I "$RUNTIME/Modules" -L "$RUNTIME" -lCuppaRuntime \
  -DDEBUG \
  -parse-as-library \
  "${sources[@]}" \
  "$PREVIEW" \
  -o "$BINARY"

"$BINARY" "$OUTPUT_DIR"
