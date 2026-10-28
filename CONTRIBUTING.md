# Contributing

## Before opening a pull request

Work from your clone's root. Inspect `git status -sb` before starting.
Read [AGENTS.md](AGENTS.md) for architecture and repository conventions.

Install Node.js and a current Swift 6/Xcode toolchain. Missing Node.js is a
test failure so JavaScript coverage cannot silently disappear.

```bash
make check
```

Keep the native modules dependency-free apart from Apple system frameworks.
The online fast path makes one HTTP request when no captive hint requires
independent confirmation. Measure latency before making performance claims.

## Choose verification by behaviour

Use the smallest relevant suite while editing, then run the release checks once
after the final changes. CI runs `make app`, which already includes `make check`
and the native WebKit suite; do not precede it with another `make check`.

| Change | Verification |
| --- | --- |
| Engine, network diagnosis, recovery or saved state | Relevant SwiftPM test filter, then `make check` |
| Form interpretation, navigation, consent or credential policy | `make js-test`, native portal tests, and `make webview-smoke` |
| Local model prompts, schema or integration | Above, on a supported Mac with actual Apple-model cases passing; use `make local-model-smoke` for focused proof or if the normal suite skipped them |
| UI, preferences, status or Activity | `make swift-test`, `make swift-build`, production UI previews and inspection of affected states |
| Release or installed baseline | `make app`; verify the installed bundle, signature and running path |

`make local-model-smoke` requires actual Apple model calls and fails if the model
is unavailable or no matching scenarios execute. The ordinary WebKit suite
explicitly skips model scenarios on unsupported Macs. A green hosted CI build
therefore proves the deterministic and browser paths, not successful local
inference. Use `WIFI_PORTAL_SMOKE_FILTER='Vision Express' make local-model-smoke`
for a focused registration → login → grant check while investigating that flow;
run the full model cases before baselining an integration change. Actual model
passes in the complete WebKit suite already satisfy that requirement; do not
repeat them through the strict target merely to run another command.

The browser fixture validates the received values and grant independently of
the automation's reported submission. The model scenarios additionally require
recorded model requests and validated decisions. Outbound connections from the
fixture process are denied when `sandbox-exec` is available; this is not a
machine-wide firewall around Apple's separate model service. A fixture pass is
not evidence of a fresh live join at a venue.

Keep tests for distinct failures: no network route, stale network state,
redirect/cookie continuity, unknown required controls, model abstention,
marketing refusal, real credentials and independent access verification.
Native engine, JavaScript and Swift browser boundary checks can cover the same rule because
they execute different parsers or consumers. The shared field descriptor corpus
and correction format contract deliberately catch disagreement between them.

Remove tests when their production behaviour has been removed, or when an
equivalent assertion already exercises the same path. Avoid tests that assert
an obsolete symbol is absent, test prose wording in fixture documentation, or
merely prove another test can fail. Do not delete useful boundary cases just to
reduce a count. Prefer a regression that recreates the user-visible failure over
several assertions that mirror its implementation. New UI copy alone does not
need a test unless its meaning affects a decision or safety boundary.

When testing the native app, restore any changed preferences and close test
windows and automation sessions. Tests must use temporary data and must not
overwrite the user's Persona, clipboard or monitoring service.

## Portal fixtures

Never submit a raw field capture. Start with the generated
`safe_report.json`, then build a synthetic fixture that preserves
only the form structure needed by the regression test. Remove or replace:

- cookies and authorization headers;
- redirect query strings and hidden token values;
- client, gateway, access-point and venue identifiers;
- IP and MAC addresses;
- all identity values.

## New handlers

1. Add a failing synthetic test.
2. Implement the narrowest handler or generic-parser improvement.
3. Verify success with an independent connectivity probe.
4. Document whether the venue requires OTP, OAuth, CAPTCHA, payment or other
   unsupported interaction.
5. Never weaken the generic safety rules to make one venue pass.
6. Never execute arbitrary portal JavaScript or accept an unreviewed
   downloadable recipe. Provider adapters must use an allow-listed set of
   HTTP transitions and fail closed on unknown required steps.
7. Do not mark a handler field-proven until a fresh live cold join succeeds;
   fixture coverage alone is not enough.

## Repository upkeep

Keep one current implementation guide and one verification record. Remove
superseded plans and reports instead of retaining parallel instructions; Git
preserves their history. Document implemented behavior and explicit limitations,
not speculative features as if they shipped.

Use `make clean` to remove Swift build output and the generated app bundle.
It does not remove saved Persona data, captures or private QA
evidence. Keep private evidence outside the checkout and generated artifacts
out of commits. Do not use a blanket `git clean -xfd` on a working installation.

The supported app is native macOS. Platform ports should introduce a working
implementation and relevant tests before adding an extensive porting manual.

Preserve compatibility identifiers and saved-data migrations when changing
module names or packaging.

## Native module ownership

`CuppaCore` defines data contracts and effect protocols. `CuppaNetworking`
implements network I/O; `CuppaPortals` implements observed portal workflows;
`CuppaEngine` coordinates bounded attempts and persists outcomes. The app
target owns UI, WebKit and Foundation Models. Dependencies point inward to
Core; tests inject I/O at those boundaries. Do not introduce a subprocess
interpreter, a downloadable executor, or a second copy of form semantics.

Use `swift test --package-path macos/CuppaAutologinApp --filter <Suite>` for a
focused test. The loopback fixture server is a separate Swift executable used
only by tests and never copied into the app. Shared synthetic portal fixtures
live in `macos/TestFixtures/Portal`; Swift and JavaScript consumers use the same
field descriptor corpus. Production rules live in `macos/Resources`.

The [case audit](docs/parity/README.md) accounts for all 401 frozen legacy tests.
`make parity-audit` verifies complete accounting, the pinned inventory hash and
real native test symbols without needing archived source or network access.
The inventory retains each original test body hash and its source location;
the case table refers to the v1 reference implementation (archived privately). Regenerate the table with
`node scripts/verify-parity.mjs --report` after changing replacement references.
Passing that metadata gate does not replace executing or
reviewing the assertions. Keep replacements tied to externally observable
behavior. Record deliberate behavior changes explicitly instead of labelling
them equivalent. The default suite also rejects Python helpers in `macos/`.
