#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT/macos/CuppaAutologinApp" --product CuppaRuntime
RUNTIME="$(swift build --package-path "$ROOT/macos/CuppaAutologinApp" --show-bin-path)"
LINK_FLAGS=(-I "$RUNTIME" -I "$RUNTIME/Modules" -L "$RUNTIME" -lCuppaRuntime)
SOURCE="$ROOT/macos/CuppaAutologinApp/Sources/CuppaAutologin"
TEST="$ROOT/macos/CuppaAutologinApp/Tests/SelfTest.swift"
BINARY="$(mktemp -t wifi-autologin-swift-tests)"
MODEL_BINARY="$(mktemp -t wifi-autologin-model-tests)"
IDENTITY_BINARY="$(mktemp -t wifi-autologin-identity-tests)"
TEST_DATA="$(mktemp -d -t wifi-autologin-model-data)"
trap 'rm -f "$BINARY" "$MODEL_BINARY" "$IDENTITY_BINARY"; rm -rf "$TEST_DATA"' EXIT

swiftc "${LINK_FLAGS[@]}" "$SOURCE/SystemPaths.swift" "$SOURCE/FakeIdentity.swift" \
  "$ROOT/macos/CuppaAutologinApp/Tests/IdentityStoreRegression.swift" -o "$IDENTITY_BINARY"
WIFI_AUTOLOGIN_DATA_DIR="$TEST_DATA/identity" "$IDENTITY_BINARY"

swiftc "${LINK_FLAGS[@]}" \
  "$SOURCE/ActiveOperation.swift" \
  "$SOURCE/AgentState.swift" \
  "$SOURCE/GatewayMAC.swift" \
  "$SOURCE/SystemPaths.swift" \
  "$SOURCE/FakeIdentity.swift" \
  "$SOURCE/AgentPreferences.swift" \
  "$SOURCE/PortalRetrySchedule.swift" \
  "$SOURCE/ManualSignInPolicy.swift" \
  "$SOURCE/ActivityLog.swift" \
  "$SOURCE/ProcessRunner.swift" \
  "$SOURCE/SpeedTest.swift" \
  "$SOURCE/WebViewHandoff.swift" \
  "$SOURCE/PortalDiagnostics.swift" \
  "$SOURCE/PortalCredentials.swift" \
  "$SOURCE/LocalPortalReasoner.swift" \
  "$TEST" \
  -o "$BINARY"
WIFI_AUTOLOGIN_DATA_DIR="$TEST_DATA/self-test" "$BINARY"

sources=()
while IFS= read -r source; do
  case "$(basename "$source")" in
    CuppaAutologinApp.swift) ;;
    *) sources+=("$source") ;;
  esac
done < <(find "$SOURCE" -maxdepth 1 -name '*.swift' -print | sort)
swiftc "${LINK_FLAGS[@]}" -DDEBUG -parse-as-library "${sources[@]}" \
  "$ROOT/macos/CuppaAutologinApp/Tests/StatusModelRegression.swift" -o "$MODEL_BINARY"
WIFI_AUTOLOGIN_DATA_DIR="$TEST_DATA" "$MODEL_BINARY"
