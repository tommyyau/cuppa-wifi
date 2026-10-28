# Portal patterns and coverage

Start with the flow and network evidence before adding a venue-specific
handler. A shop's branding is not its protocol: individual locations can use
different providers, controllers and verification requirements. This catalogue
records observed contracts and implemented paths, not a guarantee for every
branch. [Verification](VERIFICATION.md) separates fixture results from live
access grants.

## Shared patterns

| Flow | Implementation and boundary |
| --- | --- |
| Connect or terms click-through | Follow the actual eligible grant action, then verify access |
| Registration form | Fill observed fields from the saved Persona; preserve hidden tokens and cookies |
| Create account, then login | Prefer signup when no credentials are known; recover explicit duplicate-email rejection with the submitted account; remember independently verified accounts for the same non-shared gateway and origin |
| Multi-stage profile/consent | Inspect each current stage; do not submit hidden future forms blindly |
| JavaScript form | Hand the session to native WebKit; use validated local interpretation for uncertain controls |
| Verification or entitlement | Stop for codes, CAPTCHA, issued vouchers, payment, genuine identity or required marketing |
| No reachable portal | Diagnose route, address, gateway and DNS; do not guess different form values |

Recognised fields include names, email, password confirmations, phone, DOB/age,
address, country, title, privacy-preserving gender, occupation and visit reason.
Dropdowns and radios use observed choices matching saved details. Unknown
required identifiers need assistance, not plausible invented text.

Email-domain checks do not establish mailbox ownership or deliverability.
Generated Gmail-shaped addresses cannot receive verification codes. Some
providers reject the reserved UK drama-number range in every format. Corrections
preserve the saved contact; `persona_phone_rejected` requires a user-configured
contact or manual completion. The retired generated-real-number fallback must
not be reintroduced. Optional marketing is declined, including preselected
controls; explicit opt-outs are selected.

## Authorization lag and grant ambiguity

Registration and controller authorization are separate. Meraki and UniFi can
return a successful portal response before the gateway opens internet access.
Use bounded settle-and-reprobe after the grant instead of treating the first
captive probe as a rejected form or a successful page as proof of access.

An explicit Meraki `/splash/.../grant` can also stall or close without a response.
The reviewed same-origin transition preserves its landing context and hands
over to WebKit; a pending handoff suppresses duplicate static grant requests.
The missing response itself never earns automatic success. Costa's nearby
terms checkbox and image-only grant anchor have a rendered regression fixture.

## Provider contracts

### Meraki click-through and registration

Portals like Boots, Pret, Costa and Vision Express use `network-auth.com`. A
click-through page commonly exposes a `/splash/<id>/grant` anchor. Registration
is a distinct form flow; do not assume every Meraki portal is click-through.

Vision Express has a returning-account page and a separate create-account
branch. Its registration form asks for name, matching emails and matching
passwords, despite omitting HTML `required`. Shared interpretation resolves
name/username ambiguity, while code supplies values and preserves the new
account across navigation. No Vision Express-specific executor is used.

Pre-auth DNS can be blocked even when DHCP advertises public resolvers. Scoped
DNS includes the gateway as a final resolver candidate. WebSheet may also leave
Wi-Fi without a default route; the native relay keeps WebKit on that interface.
A slow decoration must not prevent inspection of an already usable form.

### Wireless Social and Nando's

Supported Wireless Social portal examples include Tenpin, Wingstop, Boom
Battle Bar, PizzaExpress and Popeyes on `wifi.wireless-social.com`. The
reviewed adapter follows the browser-delivered journey schema: email
authentication, required profile, consent continuation and post-
auth/controller grant. It validates endpoints and response shapes instead of
executing provider JavaScript or blindly posting all landing-page forms.

Only declared required profile fields are submitted, and marketing remains off.
Email-domain and phone validation can still reject fictional details. Errors
such as `privacy_email_required` and `persona_phone_rejected` explain the stop;
SMS/email verification is never automated.

The supported Nando's Connect flow instead derives a constrained Meraki grant
from the landing parameters. Its adapter performs that protocol directly.

A restaurant-chain portal used a FortiGate callback on the current gateway's
port 1000 while ordinary HTTP probes failed. Captive-assistant discovery
accepts only the reviewed provider path and `/fgtauth` callback. Discovery is
regression-tested; the Fortinet post-auth grant still requires a fresh live
cold-join confirmation.

### Fydelia / UniFi

Supported Fydelia portals include Black Sheep Coffee on `*.fydelia.com`. The
WordPress splash fronts a UniFi controller. Native form submission must retain
the entry URL's controller parameters even if an intermediate redirect
stripped them. Analytics and loyalty AJAX endpoints are not the network grant.

The adapter handles the two-stage form, local phone format beside a separate
country-code selector, required Wi-Fi terms and the marketing question with all
channels off. It then verifies the controller grant with bounded reprobes.
A fresh live join remains necessary before claiming a new provider variant.

### BT Wi-Fi

The adapter covers modern `portal.btwifi.com` guest registration
(such as Santander Work Café) and legacy `www.btwifi.com:8443`
(such as Picturehouse).
It follows only reviewed network-grant forms, declines marketing and stops at
the connected page rather than following venue promotions. The generic parser
can delegate an already-fetched BT page when an in-page redirect reveals the
provider. Remembered sessions may already be online without a new submission.

### Generic forms and gateway-hosted portals

Pret, Boots, Starbucks and Tim Hortons use shared HTML/rendered helpers when no
protocol-specific adapter applies. Tim Hortons has a friendly registry name,
not a separate implementation.

Some controllers drop public HTTP rather than redirect it. If the gateway
answers with a validated captive sign-in location, discovery continues through
the same handler chain. Router administration pages are not sign-in evidence.
Detailed discovery and unusable-network behavior live in
[Architecture](ARCHITECTURE.md#check-and-login-lifecycle).

## Diagnosing a failure

Run `'/Applications/Cuppa Wi-Fi.app/Contents/MacOS/CuppaAutologin' --triage` for a timeline, then
`--triage latest` or `--triage <venue>` for the matching attempt. The detailed
output can contain private capture content. Start with structural reports and
review [SECURITY](../SECURITY.md) before sharing.

| Evidence | Next investigation |
| --- | --- |
| `portal_dns_unavailable` / `portal_transport_unavailable` | Network scope and reachability; changing identity cannot fix transport |
| `no_supported_form_found` | Rendered form, unsupported widgets or an unrelated page |
| `*_completed_but_portal_remains` | Missing controller grant or authorization delay |
| `verification_code_required`, `captcha_required`, credential/identity/marketing gate | Preserve the session for assistance; do not burn retries or reset Wi-Fi |
| `privacy_email_required` / `persona_phone_rejected` | Provider validation rejected configured contact details |
| `online_without_accepted_automatic_submission` | Access exists, but automatic attribution is unproven; inspect the action sequence |
| Untrusted endpoint / unexpected schema | Validate the captured provider transition before changing allow-lists |

Inspect the captured sequence, controller parameters, validation categories and
independent probe result. Shared redundancy MACs are not unique venue identities.
A new protocol requires a synthetic regression and reviewed endpoint rules;
new branding alone does not justify a handler. A live cold join is required to
promote a variant from fixture-tested to field-proven. Test and contribution
requirements are in [CONTRIBUTING](../CONTRIBUTING.md).
