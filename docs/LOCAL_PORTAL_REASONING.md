# Local reasoning for unfamiliar captive portals

The browser uses Apple's on-device
`SystemLanguageModel` as an optional interpreter of ambiguous form metadata.
The HTTP engine and known provider handlers remain the first path.

## Operation before internet access

Keep the menu-bar app open and automatic monitoring enabled. The installed
LaunchAgent runs at load, watches network configuration changes and checks at
the configured interval (30 seconds by default). It reads the Wi-Fi route and
macOS captive state and sends short detection probes. Those requests can be
intercepted by the captive gateway; successful public internet access is not
required to detect a redirect. A macOS WebSheet hint also prevents failed public
DNS/probes from being mistaken for an ordinary offline connection. Existing
DNS-independent diagnostics can discover an intercepted portal by IP.

The engine writes a local, network-scoped browser handoff. The running app
checks for it every five seconds and starts WebKit automatically. This does not
require a cloud agent, API key, successful external HTTPS request or manual
invocation of the form helper. Portal pages and their resources must still be
reachable through the captive network.

On macOS 14+, the handoff also carries the Wi-Fi interface and current gateway.
WebKit uses a private, session-only data store with an authenticated loopback
CONNECT relay. The relay uses the engine's interface-bound sockets and scoped
DNS for portal pages, redirects, subresources and form submissions. TLS remains
between WebKit and the portal. This repairs the recurring WebSheet case where
the HTTP engine can reach a portal but WebKit's default route reports `-1009`.
The relay also permits the current gateway's HTTP(S) and existing port-1000
controller callback. It changes no system proxy settings, disables direct
failover and exits when the browser session or parent app ends. macOS 13 keeps
the system browser transport; the interface-scoped relay API is unavailable.

Local interpretation needs macOS 26+, an Apple Intelligence eligible Mac,
Apple Intelligence enabled, and the system model downloaded **before** joining
guest Wi-Fi that still needs sign-in. Availability is checked at controller creation
and before each inference. No download or cloud model is attempted by the app.
Older Macs, missing models, errors and timeouts keep the repaired deterministic
path and assisted completion. The base application still targets macOS 13.

Apple documents the local model and availability contract in
[SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
and [generation and task guidance](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models).
The framework also offers other model backends; this implementation explicitly
uses `SystemLanguageModel.default` and configures no remote backend.

## Interpreter and executor

1. Observe visible, enabled controls and their labels, descriptions, fieldset
   context, native types, autocomplete attributes and offered choices.
2. Fill recognised ordinary fields from the saved Persona. Re-observe up to
   four times when filling reveals conditional fields. Existing type and
   autocomplete rules retain priority.
3. Ask the local model to classify one unresolved or conflicting control or unfamiliar
   consent checkbox at a time into a fixed set of meanings. Interpret labels
   across languages using a short, task-specific prompt. For custom comboboxes,
   open the associated popup first so classification can see its choices.
4. Match dropdown values deterministically using both submitted values and
   visible labels. Country aliases work across GB/GBR/Britain/United Kingdom;
   month names take precedence over potentially zero-based submitted numbers.
   For remaining ambiguity, the model selects an observed option ID.
5. Use the established action ranking for recognised continuations, including
   plain submit buttons. The interpreter does not veto that path. Otherwise,
   ask the model to choose an observed eligible action or decline to choose.
   Repeat observation after navigation or a changed form stage.

Registration controls are interpreted even when the portal omits HTML
`required`, as Vision Express does. Conflicting name/username evidence must be
resolved before submission. Native model requests exclude unsupported meaning
categories, and a rejected request now receives an explicit empty response
instead of silently waiting for a timeout.

An initial returning-account form needs explicit or previously verified,
venue-scoped credentials. Otherwise, when an explicit guest or create-account
branch exists, the executor takes it, fills ordinary
details plus matching email/password confirmations, then reuses that new
account for a same-origin login in the current journey. The native controller
preserves this authorization across full page navigation; credentials never
enter model observations or journey reports. Required username/new-password
controls also work for new accounts. Existing and create credential operations
remain distinct. A signup at another origin does not inherit the first origin's
account authorization.

For model requests, native code derives `accountOperation` from the credentials
authorized for the current frame origin. It replaces any page-supplied account
claim, and supplies no username or password to the model. Existing-account
action instructions select login/activation and exclude another registration.
When a login button is unfamiliar, a familiar signup link outside that form
cannot override this workflow; the model can interpret the eligible control or
abstain. Activity records when a remembered venue/origin account selects login.

The model supplies meanings and opaque IDs, not JavaScript, URLs, POST bodies,
identity values or credentials. Separate guided response schemas handle field
classification and single-choice selection, with separate instructions for
fields, options and actions. A dynamic choice schema constrains
sampling to the actual offered IDs plus `none`, preventing option labels or
submitted values from being returned in place of IDs. Deterministic code fills the
Persona and clicks the validated observed control.

Requests contain bounded page metadata and the desired option meaning, such
as a country or birth month. They do not read existing input values, passwords
or cookies. URL/email text and long tokens in metadata are scrubbed. Inference
uses a fresh session for each request; the full page and journey history are
not accumulated in a small model context.

Both Swift and JavaScript validate response IDs and meanings. Stage hashes
include labels, descriptions and choice text, so a response cannot be applied
to a changed field or stage. Custom options are rechecked for changed labels,
attachment and eligibility. Repeated unresolved classifications of the same
control shape stop after three distinct passes: reading, focused translation,
and contextual comparison. Agreement between the first two permits filling;
disagreement invokes comparison before writing. A rejected interpreted field
can use its remaining pass to revisit the meaning while accepted fields stay
untouched. Entered values and raw validation messages remain outside requests.
Labels and linked instructions are separate inputs, so a generic heading
cannot silently replace a specific request. Translation produces both parts;
the shared field rules cross-check clear translated meanings. A generic name
translation cannot resolve a conflicting given-name/family-name category.
Weak address wording in a description needs interpretation when the field
does not establish a physical location. Clear access/marketing checkboxes use
the existing consent rules and spend no model requests.
Comparison retains abstentions as evidence. An unspecified identifier or
reference requires assistance unless the field itself identifies a supported
personal detail; registration context alone cannot justify a model guess.

There are at most twelve model requests across the native journey. Each gets at
most five seconds and remains inside the browser's 90-second overall deadline,
eight-action budget and twelve-navigation limit. A custom dropdown opening is
a counted observation action; its subsequent selection is bounded. Cancellation,
navigation and completion cancel outstanding native reasoning tasks.

The browser budget starts when HTTP discovery hands over, so time already
spent fetching the portal does not consume it. Individual browser requests
share that deadline. Form inspection starts at document readiness, including
the `interactive` state; blocked images must not delay a usable form. A page
without usable controls can still wait for late scripts or frames within the
same deadline. Recent progress remains visible throughout this window.

## Failure boundaries

If the portal is unreachable, the model has no form to interpret.
[Network diagnosis](ARCHITECTURE.md#network-transport) runs
without model calls and explains the result in Activity.

Verification codes, CAPTCHA, missing account credentials, booking/voucher credentials,
required marketing and genuine identity requirements remain automatic stopping
conditions. Interpreted verification is checked again before filling or
continuing. References or identifiers issued by a venue are gated before model
classification; the model is not trusted to reinterpret them as personal names.
Unknown required details are not fabricated. An apparent portal
submission still requires the engine's independent connectivity verification
before the app records success.

## Verification

`make local-model-smoke` requires the system model and actual inference calls.
It fails if the model is unavailable or the scenario selection is empty.
`make webview-smoke` explicitly skips model cases on unsupported Macs, so a
passing hosted CI run alone cannot establish local inference.

The native fixtures validate received values and grants independently of the
executor's reported submission. Model cases additionally require recorded model
requests and validated decisions. Stopping cases require empty unresolved
inputs and zero automatic actions. JavaScript tests exercise stale, invalid and
unresponsive responses, metadata privacy and request quotas.

On supported test hosts, the fixture app and relay run with outbound IP access
denied except loopback, verified before scenarios start. This tests those
processes without WAN access; it does not firewall Apple's separate service.
The implementation explicitly selects the on-device model and has no cloud
fallback. Neither fixture success nor model availability proves a live venue
join: see the [verification record](VERIFICATION.md).

Use `WIFI_PORTAL_SMOKE_FILTER` for focused scenario selection and
`WIFI_PORTAL_SMOKE_TRACE=1` for synthetic request metadata. Normal release
checks run the full suite. For general test selection, see
[CONTRIBUTING](../CONTRIBUTING.md).
