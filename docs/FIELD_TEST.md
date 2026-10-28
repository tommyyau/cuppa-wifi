# Venue acceptance for the native release

The local and hosted checks are recorded in [VERIFICATION.md](VERIFICATION.md).
These checks need an actual captive venue and are the remaining field work.
Keep Cuppa Wi-Fi running with monitoring enabled, then join the venue Wi-Fi.

| Scenario | What to observe |
|---|---|
| Fresh guest join | Activity shows detection, the observed form or browser journey, and independently verified access. Check that an ordinary website loads. |
| Returning account | On a venue with a previously verified saved account, Activity shows remembered-account sign-in; it should not create another account. |
| JavaScript portal | A form controlled by the page's JavaScript reaches the browser path and completes its real workflow. Model use, when needed, appears in local journey diagnostics. |
| Required human step | OTP, CAPTCHA, issued credentials, payment or required marketing stops for assistance. A manual completion remains recorded as assisted. |
| Competing connection | With another connection active, captive Wi-Fi traffic still uses Wi-Fi. A working Ethernet/VPN route must not falsely confirm the venue grant. |
| Rejoin and popup cleanup | After disconnecting and returning, confirm the current network is rechecked, failures do not carry over from another venue, and an obsolete macOS captive popup closes only after access is verified. |

One venue may cover several scenarios. If it stalls, retain the app's local
Activity and diagnostics with the approximate time and venue name. Raw captures
can contain private session data; use the generated safe structural report for
repository fixtures. A venue's own service outage is distinct from an app
failure, so retain the connectivity diagnosis too.

## Coverage and remaining acceptance

A retail-chain portal returned a valid chunked response that the HTTP reader
rejected before reaching its Continue link. The reader now measures chunk
delimiters relative to the remaining buffer. Synthetic socket and grant
fixtures cover the correction; a fresh automatic captive join remains to be
verified.

A coffee-chain portal showed proxy interference during connectivity checks,
and the local monitoring service was disabled. These are connectivity and
service recovery observations on an already connected network, not proof of
automatic sign-in. Synthetic regressions cover proxy categorisation and
disabled-service recovery.

Keep visit times, branch locations, device addresses and raw session details
in private diagnostics, outside this repository.
