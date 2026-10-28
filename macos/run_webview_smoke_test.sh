#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT/macos/CuppaAutologinApp" --product CuppaRuntime
swift build --package-path "$ROOT/macos/CuppaAutologinApp" --product CuppaFixtureServer
RUNTIME="$(swift build --package-path "$ROOT/macos/CuppaAutologinApp" --show-bin-path)"
SOURCE="$ROOT/macos/CuppaAutologinApp/Sources/CuppaAutologin"
TEST="$ROOT/macos/CuppaAutologinApp/Tests/NativeWebViewSmoke.swift"
SCRIPT="$ROOT/macos/Resources/autofill.js"
LADDER="$ROOT/macos/Resources/correction-ladder.json"
TEMP_DIR="$(mktemp -d -t wifi-autologin-webview-smoke)"
BINARY="$TEMP_DIR/smoke"
cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

"$RUNTIME/CuppaFixtureServer" "$TEMP_DIR/server-url" "$ROOT/macos/CuppaAutologinApp/Tests/fixtures" > "$TEMP_DIR/server.log" 2>&1 &
SERVER_PID=$!
for attempt in {1..300}; do
  [[ -s "$TEMP_DIR/server-url" ]] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "WebKit fixture server exited before becoming ready" >&2
    cat "$TEMP_DIR/server.log" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! -s "$TEMP_DIR/server-url" ]]; then
  echo "WebKit fixture server did not become ready within 30 seconds" >&2
  cat "$TEMP_DIR/server.log" >&2
  exit 1
fi
SERVER_URL="$(cat "$TEMP_DIR/server-url")"

swiftc \
  -I "$RUNTIME" -I "$RUNTIME/Modules" -L "$RUNTIME" -lCuppaRuntime \
  "$SOURCE/AgentState.swift" \
  "$SOURCE/ActivityLog.swift" \
  "$SOURCE/GatewayMAC.swift" \
  "$SOURCE/SystemPaths.swift" \
  "$SOURCE/FakeIdentity.swift" \
  "$SOURCE/WebViewHandoff.swift" \
  "$SOURCE/PortalDiagnostics.swift" \
  "$SOURCE/PortalCredentials.swift" \
  "$SOURCE/PortalBrowserTransport.swift" \
  "$SOURCE/LocalPortalReasoner.swift" \
  "$SOURCE/WebViewAutopilotController.swift" \
  "$ROOT/macos/CuppaAutologinApp/Tests/LocalPortalSmokeScenarios.swift" \
  "$TEST" \
  -framework AppKit \
  -framework WebKit \
  -o "$BINARY"
if command -v sandbox-exec >/dev/null 2>&1; then
  # Exercise the local model/browser with outbound IP traffic denied, while
  # keeping loopback available for the captive-session fixture server.
  cat > "$TEMP_DIR/offline.sb" <<'PROFILE'
(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
PROFILE
  sandbox-exec -f "$TEMP_DIR/offline.sb" "$BINARY" "$SCRIPT" "$LADDER" "$SERVER_URL" --wan-denied
else
  echo "WAN isolation unavailable; browser fixtures remain local"
  "$BINARY" "$SCRIPT" "$LADDER" "$SERVER_URL"
fi
