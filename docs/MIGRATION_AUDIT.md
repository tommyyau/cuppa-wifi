# V1 to native Swift migration audit

This document preserves behaviour contracts for the native Swift migration.
Current module ownership lives in [ARCHITECTURE.md](ARCHITECTURE.md).
Historical source identifiers in the frozen inventory describe provenance;
building and checking this tree needs no historical checkout.

The [case-level audit](parity/README.md) records every one of the **401 declared
legacy tests across 34 modules**, with the original method, a real native test
symbol, a disposition and the assertion-level rationale. The frozen inventory
also records each original test body hash. This replaces the earlier family-only
mapping; a lower number of Swift methods does not remove the original behaviors.

Run `make parity-audit` to reject missing or duplicate mappings, changes to the
hash-pinned inventory and nonexistent native test references. Original methods
are recorded by name and test-body hash; no legacy checkout or interpreter is needed.
Run `make app` to execute the
complete native, JavaScript, Swift UI/persistence and real WebKit suites and
package the release. The metadata gate cannot prove semantic equivalence by
itself: the mapping was reviewed against original assertions, gaps were added
as executable regressions, and the suites must pass. See [VERIFICATION.md](VERIFICATION.md) for the checks to run and their limits.

## Deliberate differences

- Native Network.framework interface binding, DNS fallback, HTTP status returns
  and Foundation Process replace Python-specific mechanisms. Actual scoped
  IPv4/IPv6 transfers, DNS, TLS identity checks, relay bytes and child-process
  termination test the replacement behavior.
- Unknown required controls are not filled with arbitrary invented values.
  Generic HTML ambiguity escalates to WebKit/model interpretation without a
  static POST; explicit issued credentials, OTP and other assistance boundaries
  remain terminal. The low-level synthesis differences are identified per case.
- Safe diagnostics hash field identifiers and omit arbitrary labels; raw local
  evidence remains private. Bounded model metrics follow the native controller's
  budget. Outcome/reason names and ownership changes are recorded in the rows.
- The Python-only fallback to a repository-local data folder when home is absent
  is retired: the signed app has no runtime repository, and Foundation supplies
  the account home. Explicit data-root overrides and legacy Persona copying are
  tested, including the real native installer.
- Foundation cookie handling rejects insecure delivery of Secure cookies.

## Native-only test support

The normal test run uses a Swift fixture server, the production native browser
relay, and a native child process for large stdout/stderr regression checks.
The obsolete Python browser proxy and WebKit server helpers are deleted.
`scripts/verify-native-tests.mjs` rejects Python files or interpreter invocations
in the macOS source/helper tree. The Python implementation, tests and build targets
have been removed from the maintained tree. Shared synthetic fixtures remain in
`macos/TestFixtures/Portal`, consumed by native and JavaScript tests. No Python is
needed to build, test or run the app.

## Evidence boundaries

Synthetic tests use temporary state, independent server-grant oracles and
injected network/clock/recovery boundaries. Loopback integrations exercise real
sockets, TLS and WebKit. Local Apple-model cases require actual requests and
validated decisions, not just model availability. Hosted CI explicitly skips
those model cases on unsupported hosts; a supported Mac must run them explicitly.

Only [physical venue acceptance](FIELD_TEST.md) remains outside automated
reproduction: a fresh captive join, remembered-account return and physical
competing-interface behavior. Home-network ONLINE status is not a venue result.

## Required contracts: networking and discovery

- Wi-Fi interface/default route, gateway IP/MAC, SSID and DHCP domain remain independently observable; missing/redacted SSID must not invent a network switch. Known gateway, known SSID or DHCP-domain changes clear prior venue/login/failure/diagnostic context.
- Dormancy runs **before HTTP**: configured ignored gateway, personal hotspot when enabled, and positively identified non-Wi-Fi default route. Failure to enumerate Wi-Fi interfaces is not evidence for dormancy.
- Preserve shared-gateway recognition (HSRP v1/v2, GLBP, VRRP). Shared virtual MACs cannot scope credential persistence or venue verdicts. Fingerprint precedence is unique gateway MAC, otherwise portal domain, SSID, DHCP domain, fallback. No identifiable fingerprint must not reuse another venue verdict.
- HTTP sockets bind to the selected interface for IPv4 and IPv6. Scoped DNS fallback reads the interface's DNS servers and appends DHCP router as last resort; normal DNS failure must not silently use another interface.
- Preserve hostname/TLS verification while connecting through resolved addresses. Never globally trust certificates or treat CONNECT tunnelling as permission to rewrite TLS.
- Probe redirects are captured without following; relative redirects are resolved. Apple Success accepts only the narrow detector document. Arbitrary HTML containing Success stays captive. Probe bodies are bounded at 64 KiB.
- Ordinary healthy checks can accept a normal reachable detector. Post-login verification and stale WebSheet override require **Apple plus Google success**. Secondary success alone, Apple plus secondary timeout, and Apple plus secondary redirect fail consensus.
- Both probes failing without a captive hint means NO_NETWORK, not a fabricated portal. A macOS captive hint can retain CAPTIVE despite unavailable probes.
- Discovery order: observed probe redirect, gateway-hosted portal, trusted recent CNA callback. CNA recovery verifies provider, controller callback gateway, port/path/token shape and newest matching record.
- Network diagnosis distinguishes self-assigned address, DNS failure, filtered ping, HTTP reachability, permission denial and uncertainty. Router admin/ordinary web redirects are not captive evidence. Dribbling headers must not extend deadline.
- Re-read interface/gateway before accepting diagnosis; a network switch discards its redirect/evidence. No sign-in attempt means no failure count/radio reset.

## Required contracts: static form execution and safety

- Preserve form ranking and search-form exclusion; empty hidden JS templates must not beat actual visible forms. Parse nested labels, placeholders, ARIA, autocomplete and native input types with disabled/readonly rules.
- Preserve hidden server values and fresh tokens; include the selected positive named submit control; GET forms use encoded query, POST forms use proper encoded bodies.
- Persona mappings cover names, email, username/password where authorized, UK phone, split DOB, address/postcode/city/county/country, gender/title, age/company/occupation/visit/customer fields. Constraints and selected options come from observed controls.
- Consent means required terms/access consent only. Marketing opt-in remains false, opt-out remains selected where provided; required marketing cannot be accepted automatically.
- Do not invent issued voucher/member/government/sponsor/OTP credentials, automate CAPTCHA/payment/eligibility checks, use social sign-in, or treat an unknown required field as a safe arbitrary token. Optional dormant challenge copy must not block an otherwise ordinary form.
- Plain credentials authorize explicit existing/create operation at exact scheme/host/effective port. Insecure, oversized or malformed credential files are rejected. Recognizing a password control does not authorize logging into an arbitrary existing account.
- Validation corrections preserve identity: phone formatting changes retain digits, postcode spacing and DOB representation changes retain values. Never replace a rejected phone/email/name with another identity. Rejected fields alone are corrected; accepted/server fields stay intact. OTP appearing mid-correction stops further automation.
- Budgets apply across delegated handlers and every request, not per helper. No request is issued after deadline. Repeated unchanged form escalates after an accepted submission rather than reposting indefinitely.
- Follow safe meta refresh, literal JS redirects and explicit connect controls; do not execute arbitrary generated code. Terms documents, promotions and signup links are not grant actions.
- Navigation rejects non-HTTP schemes, public-to-local/LAN pivots and HTTPS downgrades. Preserve carefully bounded same-gateway and reviewed controller grant exceptions. Public cross-origin guest submission is supported under the existing policy, not blanket same-origin denial.
- Classify transport/DNS failure separately from no supported form. JS-intercepted forms such as `preventDefault()` / `data-endpoint` escalate before a misleading static submission.
- An accepted-looking page or HTTP 200 JSON is not success: explicit JSON/server rejection fails even if internet separately becomes available. Automatic credit needs observed accepted action and independent network verification.

## Required contracts: providers and journeys

- Registry precedence: domain, SSID, MAC, generic fallback. Host matching is domain bounded, never substring matching.
- **BT Wi-Fi:** modern AJAX registration protocol, observed field/options choices, decline marketing, trusted redirects, explicit JSON rejection, unchanged page stops without reposting; legacy registration/connect path still works and generic landing delegates to provider.
- **Fydelia:** provider form targets and same-origin constraints, UK local phone formatting, marketing rejection, UniFi query/controller parameters preserved, continue URL and delayed grant settling.
- **Wireless Social:** embedded journey JSON/window strings, provider venue name and metadata-driven required fields, new versus existing-user journey, opt-out/optional postcode handling, safe phone serialization and rejected-format corrections, progress nodes including post-start, post-auth rejection, private-relay requirement for reserved email defaults, trusted relative/Meraki grant redirect and external form, cross-origin grant denial.
- **Nando's/generic venue contracts:** preserve real connect URL derivation and generic BT/Wireless Social delegation. Existing Pret/Boots/Black Sheep/Picturehouse/Nando's synthetic contracts are regressions, not proof of unseen venues.
- Preserve six distinct static stages with rotating tokens; generic engine cannot be reduced to one form POST or universally rerouted to WebKit without documenting and testing behavioral replacement.
- Settling retries follow a candidate grant within shared remaining budget. An arbitrary timed-out connect link is not a trusted Meraki ambiguous grant.

## Required contracts: handoff and rendered outcomes

- Handoff carries URL, venue fingerprint, interface, gateway, bounded cookies, schema signature/provider, first-visit and venue key, previous actions, pending submission and corrections; each protects continuity across full navigation.
- JSON remains atomic and private if retained. Browser window deadline starts at actual handoff, so a slow static attempt does not consume it beforehand. Current source uses 90-second browser/handoff freshness and 24-hour unsupported expiry, except unavailable portal pages expire after 60 seconds to allow recovery; do not copy historical shorter budgets without reconciling current code.
- Only reviewed browser failure reasons auto-escalate; unsupported reasons are manual-only. Active matching work suppresses duplicate static actions, including scheduler ticks during pending browser submission.
- Reject stale/future timestamps, expired deadline, changed fingerprint/interface/gateway/SSID, unsupported URL schemes and malformed records. Preserve legacy `js_render` compatibility if files can survive upgrade.
- Shared lock prevents static checks, browser work and completion command racing. Return/clear ownership on finish, cancellation, quit and error.
- Real WKWebView runs production autofill and deterministic validation, with bounded model metadata interpretation. Saved passwords/cookies never enter model request content; model-selected IDs/options are checked against observed controls.
- Production browser transport uses `CuppaNetworking.BrowserRelay`: authenticate loopback CONNECT, scope sockets/DNS, restrict private destination pivots and retain no-failover behavior across navigation. The v1 Python proxy is no longer shipped or invoked.
- Browser candidate completion independently reprobes, allows bounded delayed grant settling, then rechecks network identity. Page text cannot write ONLINE or remembered account.
- Assisted outcome preserves manual source even after verification; it must not update automatic-login timestamp/metrics or teach automatic strategy. Unsupported and connectivity-unverified outcomes retain distinct reasons.
- Account persistence occurs after independently verified internet, only non-shared gateway plus exact origin. Registration credentials remain the returning account even if Persona later changes; unrelated gateway, port, scheme or registration controls must not receive them.

## Required contracts: state, metrics, evidence and installation

- State schema preserves UNKNOWN/ONLINE/CAPTIVE/UNSUPPORTED/NO_NETWORK/IGNORED, check/connection/automatic-login times, login gateway, failures/reassociation time/notification marker and diagnosis. Corrupt/missing state has safe defaults; unknown keys permit upgrades.
- Atomically publish check start before long work for accurate UI cadence. ONLINE clear stale handoff/unsupported records and failure count; healthy polls do not spam activity or notifications.
- Notification transitions: first captive detection, successful/recovered online, once-per-fingerprint unsupported, give-up once at threshold. No-network never becomes repeated portal notification.
- Ordinary failure increments; unsupported does not increment/reassociate. Reassociation fallback is configurable and occurs at exactly two failures, rate-limited to ten minutes; give-up starts at four. Do not run radio actions in independent tests.
- Fast retries occur only while captive and stop for ONLINE/NO_NETWORK/IGNORED/UNSUPPORTED within 30 seconds; cadence is six seconds. Test fake clock, cancellation and no duplicate lock ownership.
- First verified success capture per fingerprint is independent of existing failure captures. Failures retain hops each time; unsupported captured once. Private raw bodies/headers/manifests remain local; body-free `safe_report.json` and diagnostics redact tokens/credentials/echoed form values.
- Capture paths are sanitized, files 0600 and directories 0700. Time collisions and atomic-write failure should be tested rather than silently replacing evidence.
- Forensic sweeps are bounded/rate-limited, delayed for first transient DNS/transport failure, skipped on successful checks, and nonfatal if failing. Recover gateway/literal-IP/CNA/JS-rendered discoveries back into normal browser path; preserve limited history.
- Triage/list/status/install-check remain available without unintended network calls. Structural report inputs are restricted to own report directory, bounded file size/counts and known field vocabulary; malformed values cannot leak originals or crash processing.
- Verified execution learning is host+schema scoped, excludes token rotation, expires after 30 days, is capped at 200 records and is never taught by unverified/manual success. First/returning/unfamiliar/assisted/unsupported counts stay separate.
- Preserve one shared data root with `WIFI_AUTOLOGIN_DATA_DIR` override; initialization/read-only status must not create or alter the real user state in tests. Legacy Persona migration copies without overwriting shared values.
- Service interval choices 10/30/60/120/300, enable/disable, idempotent installation and rollback on failure remain supported. Uninstall preserves user data. v2 migration must retire old Python LaunchAgent invocations without deleting Persona/accounts/captures.
- Package audit includes `EngineInstaller`, `SystemPaths`, `StatusModel` commands, BrowserTransport, helper resources and the generated LaunchAgent. The implementation and test helpers are native; the archived Python source is not part of this repository.
