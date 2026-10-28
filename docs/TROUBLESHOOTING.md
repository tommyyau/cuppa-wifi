# Troubleshooting and everyday use

## Getting started

Join the venue's Wi-Fi in macOS and keep Cuppa Wi-Fi open. Monitoring runs at
network changes and every 30 seconds by default. The app has five tabs:

| Tab | Purpose |
| --- | --- |
| Status | Connection state, Check Now, Test Speed, monitoring and Settle Up & Quit |
| Activity | Progress, problems, next actions, recoveries and speed results |
| Persona | Saved fictional details, persistent field labels and a password eye |
| Settings | Hotspot and automatic speed-test switches; interval and optional Wi-Fi reset under Advanced |
| Help | Permissions, sign-in limitations and troubleshooting |

Persona edits are drafts until **Save Persona** succeeds. Browser attempts use
saved details; discarding a draft cannot change an in-progress sign-in.
Set an email you control before first use and after generating a new Persona:
the app creates no inbox, and portals may email the configured address.

Allow **Local Network** access so the app can reach a venue's sign-in server.
Reading a friendly Wi-Fi name requires separate, optional Location permission.
Cuppa does not request, store or transmit coordinates.

## Connection checks blocked by a proxy

If Activity reports **Direct Wi-Fi check blocked by a proxy**, macOS selected a
proxy despite Cuppa's direct-connection preference. Private Relay can cause this;
a proxied success cannot prove access through the current venue. Cuppa leaves
access unverified and does not change system privacy settings. If you choose,
turn off **Limit IP Address Tracking** in System Settings → Wi-Fi → the current
network's Details, then select **Check Now**. This reduces Private Relay
protection on that network. Restore it when direct checks are no longer needed.
Other configured proxies may require a different remedy.

## Monitoring and speed tests

Enabling automatic monitoring also re-enables Cuppa's own launchd service if it
was persistently disabled. A failed enable/start is reported and the previous
service definition is restored; saved Persona data is preserved.

Internet access and speed are separate. A short automatic speed test runs after
a new connection unless disabled in Settings; **Test Speed** remains available
on demand. Tests use macOS `networkQuality` and transfer measurement traffic.
Routine checks make small connectivity requests, without running speed tests or
the model. Longer intervals reduce scheduled wakeups but delay detection of
silent session expiry. Battery impact has not been measured as a percentage.

**Settle Up & Quit** stops monitoring and closes the app. Reopening restores
monitoring if it was enabled before quitting. The app must remain open for
JavaScript-rendered portal assistance.

## When sign-in stops

Cuppa stops for CAPTCHA, verification codes, issued vouchers, payment, required
marketing and unsupported identity checks. It cannot repair a broken venue
network. Rejected fictional phone numbers are only reformatted; the app does
not replace them with random real numbers. Use permitted contact details or
finish manually. **Finish sign-in**, when offered, reuses the browser session.

Activity's collapsed **Troubleshooting** section contains the support summary,
local files and recorded attempt details. Summaries include network names;
review them before sharing. Raw captures can contain private session data.
Read [SECURITY.md](../SECURITY.md) before sending diagnostics.

## Reset local data

Quit Cuppa before removing `~/.local/state/wifi-autologin/` and
`~/Library/Logs/wifi-autologin.log` plus rotated log copies. This deletes saved
Persona, accounts, captures and connection state. Deleting only
`config/verified-portal-accounts.json` inside the data directory forgets remembered
accounts without removing the Persona.

UI settings and speed history also use macOS preferences under
`io.github.tommyyau.wifi-autologin`. To reset those too, while Cuppa is closed:

```bash
defaults delete io.github.tommyyau.wifi-autologin
```

This reports an error if no preferences exist. Cuppa's LaunchAgent lives in
`~/Library/LaunchAgents/com.tommyyau.wifi-autologin.plist`; use the app's monitoring
switch to disable it before uninstalling. See [engine and local files](ENGINE.md).
