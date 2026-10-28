#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macos/CuppaAutologinApp"
OUTPUT="$ROOT/dist/Cuppa Wi-Fi.app"
CONTENTS="$OUTPUT/Contents"

swift build -c release --package-path "$PACKAGE" --product CuppaAutologin
BIN_PATH="$(swift build -c release --package-path "$PACKAGE" --show-bin-path)"

rm -rf "$OUTPUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_PATH/CuppaAutologin" "$CONTENTS/MacOS/CuppaAutologin"
cp "$ROOT/macos/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/macos/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cp "$ROOT/macos/Resources/autofill.js" "$CONTENTS/Resources/autofill.js"
for file in correction-ladder.json portal-schema.json vendor-profiles.json; do
  cp "$ROOT/macos/Resources/$file" "$CONTENTS/Resources/$file"
done

# A release must contain only the compiled native runtime and reviewed resources.
if find "$CONTENTS" -type f \( -name '*.py' -o -name '*.pyc' \) | read -r _; then
  echo "Unexpected Python file in release bundle" >&2
  exit 1
fi

codesign --force --deep --sign - "$OUTPUT"
echo "$OUTPUT"
