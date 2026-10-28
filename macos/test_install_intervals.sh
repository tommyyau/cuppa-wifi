#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macos/CuppaAutologinApp"
SOURCE="$PACKAGE/Sources/CuppaAutologin"
swift build --package-path "$PACKAGE" --product CuppaRuntime
RUNTIME="$(swift build --package-path "$PACKAGE" --show-bin-path)"
BINARY="$(mktemp -t cuppa-installer-tests)"
trap 'rm -f "$BINARY"' EXIT
swiftc -I "$RUNTIME" -I "$RUNTIME/Modules" -L "$RUNTIME" -lCuppaRuntime \
  "$SOURCE/SystemPaths.swift" "$SOURCE/FakeIdentity.swift" \
  "$SOURCE/AgentPreferences.swift" "$SOURCE/ProcessRunner.swift" \
  "$SOURCE/EngineInstaller.swift" "$PACKAGE/Tests/NativeInstallerRegression.swift" -o "$BINARY"
"$BINARY"
