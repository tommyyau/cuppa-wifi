# Repository guidance

Work from the clone root and inspect `git status -sb` before editing. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for test selection and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for module ownership.

## Layout and conventions

- Native Swift runtime and UI: `macos/CuppaAutologinApp/Sources`.
- Shared portal rules and JavaScript: `macos/Resources`.
- Synthetic portal fixtures: `macos/TestFixtures/Portal`.
- Core contracts are shared by Networking, Portals and Engine; dependencies
  point inward to Core. The app owns WebKit and Foundation Models integration.
- Keep runtime modules dependency-free apart from Apple system frameworks.
- Preserve bundle/service identifiers and saved-data migration compatibility.
- Retain the frozen case inventory in `docs/parity/` and its native mappings.
- Use synthetic fixtures. Never commit raw captures, live session URLs or
  personal identifiers. Follow [SECURITY.md](SECURITY.md).
- Automate only authorised guest access. Stop for human verification, issued
  credentials, payment, required marketing or unknown identity requirements.

## Build and checks

```bash
make swift-build
make js-test
swift test --package-path macos/CuppaAutologinApp --filter CuppaPortalsTests
swift test --package-path macos/CuppaAutologinApp --filter CuppaEngineTests
make check
make webview-smoke
make local-model-smoke
make app
```

`make app` runs the release checks and produces `dist/Cuppa Wi-Fi.app`.
The strict model target requires a supported Mac and actual model calls;
skipped inference is not a passing model test. Use temporary data for tests.
Distinguish fixture results from fresh venue acceptance.

## Menu-bar icon changes

Render the production `CafeWiFiIcon` in both states: muted grey without steam
when offline, bright with animated steam when online. Preserve the two steam
frames and Reduce Motion fallback. State comes from `lastResult == "ONLINE"`.
For state-specific colours, use a non-template `NSImage`, `isTemplate = false`
and `.renderingMode(.original)`; template rendering can hide colour changes.

Run `make ui-previews` and inspect online/offline menu images and all affected
Status states in `/tmp/wifi-autologin-ui-previews`. Build and run the relevant
Swift checks. When testing a rebuilt app, verify its signature and running
binary path so the displayed result corresponds to the new bundle.
