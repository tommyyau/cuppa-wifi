# Native engine and local files

The app executable includes the complete Swift engine. Background checks use
`--engine-once`; manual diagnostics use the same binary. No interpreter, package
manager or Python installation is needed to run Cuppa Wi-Fi v2.

```bash
APP='/Applications/Cuppa Wi-Fi.app/Contents/MacOS/CuppaAutologin'
"$APP" --status
"$APP" --once
"$APP" --portal-stats
"$APP" --triage latest
"$APP" --forensics
"$APP" --ignored
"$APP" --ignore-current 'Home network'
"$APP" --install-check
```

`--status`, `--portal-stats`, `--triage` and `--ignored` read local evidence.
`--once` can submit an eligible portal form. `--forensics` makes bounded network
requests and writes private diagnostic evidence. `--ignore-current` changes the
saved ignore list. The UI owns monitoring installation, interval and pause/quit.

The shared data root remains `~/.local/state/wifi-autologin/`:

| Path | Purpose |
| --- | --- |
| `config/identity.env` | Saved literal Persona and existing hotspot/reset flags |
| `config/networks.ignore` | Ignored gateway MACs and optional labels |
| `config/account-credentials.json` | Explicit portal credentials |
| `state.json` | Connection result, current network and timestamps |
| `wifi-autologin.lock` | Cross-process check/browser exclusion |
| `webview_handoff.json` | Private browser URL, cookies and action/deadline context |
| `webview_unsupported.json` | Expiring, venue-scoped stop decision |
| `portal_progress.json` | Current value-free progress and events |
| `portal_learning.json` | Independently verified host/schema execution choices |
| `phone_policy.json` | Recorded rejection of the configured phone |
| `captures/` | Private HTTP evidence plus structural support reports |
| `forensics/` | Bounded private network diagnostic sweeps |
| `rendered-journeys/` | Sanitized static/browser outcomes and model counters |

The app keeps verified account records in its existing native account store.
Credentials and Personas are local permission-protected plaintext. They are not
model inputs. Raw diagnostic files may contain sensitive portal/session data.
See [SECURITY.md](../SECURITY.md) before sharing them.

Activity uses `~/Library/Logs/wifi-autologin.log`. The stable LaunchAgent label
is `com.tommyyau.wifi-autologin`, with its plist in `~/Library/LaunchAgents/`.
V2 points this plist at the app executable rather than a copied script. Keeping
the bundle in `/Applications` gives launchd a stable path.

Tests set `WIFI_AUTOLOGIN_DATA_DIR` to a temporary directory. This is an isolation
boundary, not an instruction to overwrite the user's current configuration.
