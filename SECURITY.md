# Security policy

## Reporting

Please report security issues privately through GitHub Security Advisories.
Do not open a public issue containing a live portal URL, cookie, token, client
MAC, gateway MAC, email, phone number, or unredacted capture.

## Sensitive local files

The following must never be committed:

- `config/identity.env`
- `config/networks.ignore`
- `captures/`
- recon packet/HTTP dumps
- `~/Library/Logs/wifi-autologin.log`
- `~/.local/state/wifi-autologin/`

Portal captures are intentionally stored with owner-only permissions. Before
sharing a fixture, remove cookies, query strings, hidden token values, client
and gateway identifiers, IP addresses, and any echoed form values. Replace
them with obvious synthetic placeholders.

Each capture directory includes `safe_report.json`, a body-free structural
summary intended for initial triage. Review it before sharing anyway. Raw
`NN_body.html` and `NN_headers.json` files must remain private.

Persona, optional explicit credentials and remembered portal accounts are local plaintext
files protected by owner-only permissions, not an encrypted credential vault.
Do not reuse a valuable account password. HTTPS portals retain normal system
TLS verification; an HTTP-only portal cannot protect submitted details in
transit. Fictional Persona details do not make a Wi-Fi connection anonymous.

Remembered accounts are written only after independent internet verification,
and reused only for the same non-shared gateway and exact portal origin
(scheme, host and port). They retain the credentials used at registration,
even if the Persona is later edited. Delete `config/verified-portal-accounts.json`
from the shared data directory to forget these accounts. Unknown and shared
virtual gateways do not enable account persistence.

The WebKit executor, reasoning replies and all native message handlers run in
the isolated `CuppaAutofill` script world. Portal scripts cannot replace the
executor, inspect its arguments or forge messages on those channels. The DOM
remains shared: a portal can read values intentionally entered into its form.

Persona passwords are supplied to the main document and frames with the same
security origin, including inherited `srcdoc` documents. Previously authorized
Persona signup origins retain access for the account journey. Cross-origin and
opaque sandboxed frames receive no Persona password. Explicit account permission
does not widen that policy; explicit and remembered credentials retain their
exact origin scope, and remembered accounts also require the venue scope.
The executor rechecks the live document's origin before filling, so a cached
frame reference cannot carry authorization across a later cross-origin navigation.
Other Persona attributes may still be filled in third-party frames. The model
receives account-operation metadata, never account values.

Marketing choices follow the visible answer and the question's polarity:
opt-in questions select refusal, opt-out questions select affirmative refusal.
Disabled, ambiguous or unavailable safe answers cannot authorize consent.

Persona saves reject missing required values and control characters before
writing, preserve literal values across the UI/native-engine readers, and atomically
replace a `0600` file. Logs are created and rotated with owner-only permissions.
Support summaries can include network names, and raw files can contain private
session data; the app does not label them universally safe to share.

The on-device model classifies observed controls and selects observed options.
It does not receive saved passwords or cookies, invent issued credentials,
execute generated code, or approve its own output. Deterministic checks still
validate IDs, consent, field constraints and workflow limits. Validated model
responses can be mistaken, so unknown steps stop for assistance and network
access is verified independently after submission.

## Project boundaries

Cuppa Wi-Fi automates ordinary guest flows that a user is entitled to
complete. It must not:

- automate CAPTCHA, OTP, payment, issued voucher, or eligibility checks, or
  use real accounts without explicitly supplied credentials;
- spoof device identity to evade session or usage limits;
- opt users into marketing;
- weaken TLS validation globally;
- submit real personal data by default.
- execute arbitrary JavaScript or unreviewed community recipes supplied by a
  captive portal.
