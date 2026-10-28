import SwiftUI

struct HelpView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cuppa Wi-Fi").font(.system(size: 22, weight: .semibold))
                    Text("Settle in. Get online.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HelpItem(
                    symbol: "wifi",
                    title: "How does automatic sign-in work?",
                    text: "Cuppa Wi-Fi checks your Wi-Fi every 30 seconds by default and after network changes. It skips ignored networks, looks for a captive portal, fills its form with your persona, follows Continue or Connect, then checks independently that internet access returned. Check Now starts an immediate attempt; it stays available when monitoring is paused."
                )
                HelpItem(
                    symbol: "text.viewfinder",
                    title: "How are form fields understood?",
                    text: "The app first reads field labels and browser hints. When a form is unfamiliar, Apple’s on-device language model can help interpret a label, choose an offered option or find the next button. Its decisions are checked before the app fills your saved persona or clicks. Activity → Troubleshooting shows how an attempt interpreted the form."
                )
                HelpItem(
                    symbol: "desktopcomputer",
                    title: "Can the Apple model work before I’m online?",
                    text: "Yes. Interpretation uses Apple’s local SystemLanguageModel with no cloud backend or API key. It needs macOS 26 or newer, a compatible Mac, Apple Intelligence enabled and the model downloaded before joining captive Wi-Fi. Keep the app open. Familiar forms need no model call; if it is unavailable, errors or times out, the app keeps its rules and offers manual help for unresolved controls. Portal pages must still be reachable on the Wi-Fi network."
                )
                HelpItem(
                    symbol: "building.2",
                    title: "Which venues are supported?",
                    text: "Cuppa Wi-Fi recognises common guest forms, including registration followed by login, across cafés, shops and other venues. The form matters more than the venue name, and a provider can change its pages. Internet access is checked after every sign-in. Verification codes, CAPTCHA, paid access, vouchers and genuine account details need you."
                )
                HelpItem(
                    symbol: "person.crop.circle",
                    title: "What does my persona send?",
                    text: "Your saved persona supplies name, email, phone, birthday, address and other recognised portal fields. Optional fields may be filled too. Required terms are accepted; marketing stays off. Edits and Generate Persona create a draft: use Save Persona to apply it or Discard Changes to restore the saved details. A sign-in already running keeps the details it started with."
                )
                HelpItem(
                    symbol: "iphone",
                    title: "What about email and phone details?",
                    text: "Generated emails look like Gmail addresses, but the app does not create or verify an inbox. The usual phone is a non-live 07700 900xxx drama number. If a portal rejects it, the app can correct its format but does not invent a replacement number. Supply a contact you control or finish manually when genuine contact details are required. Verification codes are never automated."
                )
                HelpItem(
                    symbol: "cup.and.saucer",
                    title: "What do the cup and beans mean?",
                    text: "A grey cup with no steam means the app has not confirmed internet access. A bright green steaming cup means online; Reduce Motion keeps the steam still. The five beans show measured download speed, from Single (under 5 Mbps) to Nitro (100+ Mbps). Upload and Smooth, Steady or Laggy responsiveness appear below when available."
                )
                HelpItem(
                    symbol: "speedometer",
                    title: "When does the speed test run?",
                    text: "With monitoring on, a speed test runs once after a new connection. Turn off Test speed after connecting in Settings if you prefer to run Test Speed yourself. The switch saves immediately. Tests send and download data through Apple’s measurement service, briefly use network capacity, and stop after at most 30 seconds. A test already running finishes or times out."
                )
                HelpItem(
                    symbol: "battery.75percent",
                    title: "Does monitoring use battery?",
                    text: "Background checks use some energy. A healthy check normally downloads a small connectivity page; it does not run the Apple model or a speed test. The default is every 30 seconds. A longer interval in Settings → Advanced reduces checks but takes longer to notice an expired session. Network changes trigger a check separately. Battery impact has not been measured."
                )
                HelpItem(
                    symbol: "gauge.with.dots.needle.33percent",
                    title: "I’m online, so why is it slow?",
                    text: "Internet access and connection quality are separate checks. Activity shows measured download, upload, idle latency and responsiveness, or explains that speed is unknown. Limited quality can make pages and calls slow even after sign-in succeeds. Repeating a completed portal login will not improve those measurements; try another network if performance is poor. Test results remain in Activity after switching networks."
                )
                HelpItem(
                    symbol: "safari",
                    title: "Sign-in is stuck or keeps returning. What next?",
                    text: "Activity explains the current step and what to do next. Keep the app open and allow macOS Local Network access if asked. When an attempt ends, Check Now retries it. Finish sign-in opens the existing session for a code, CAPTCHA or genuine detail; if that button is absent, open the venue’s Wi-Fi login page. Check that persona edits were saved. If the portal is unavailable or the network does not respond, ask the venue or try another network. Cuppa Wi-Fi cannot repair the venue’s service."
                )
                HelpItem(
                    symbol: "building.2",
                    title: "Why is the venue name wrong?",
                    text: "Without Location permission, the name may come from the portal provider, a saved venue or the network’s domain. Use Show Wi-Fi Name to let macOS reveal the actual Wi-Fi name, then Check Now after joining the intended network. The permission is for the name; the app does not request coordinates."
                )
                HelpItem(
                    symbol: "network",
                    title: "Could my VPN interfere?",
                    text: "A VPN or its kill switch can interfere with portal access, DNS or the connection check. If sign-in stalls, temporarily pause it, finish the Wi-Fi login and check again, then reconnect the VPN."
                )
                HelpItem(
                    symbol: "wifi.router",
                    title: "How do I pause automatic checks?",
                    text: "Turn off Auto monitoring in Status. Check Now stays available for a one-off attempt. Settings → Skip personal hotspots also skips automatic sign-in checks on recognised phone hotspots; it is on by default. Turn monitoring back on when you want automatic sign-in again."
                )
                HelpItem(
                    symbol: "wrench.and.screwdriver",
                    title: "How do I get diagnostics?",
                    text: "In Activity, expand Troubleshooting and use Copy support summary when asking for help. Recorded attempts explain which fields were understood and where sign-in stopped. Open local files gives access to captures and the raw log for a deeper investigation. The summary includes network names; raw files may also contain tokens and other identifiers. Review before sharing."
                )
                HelpItem(
                    symbol: "lock.shield",
                    title: "What stays private?",
                    text: "Form classification runs locally. Portal requests still send persona fields, cookies and the tokens needed to sign in to the venue/provider; connectivity checks contact Apple and Google. Persona files and captures stay on your Mac. Fictional details do not make you anonymous to the Wi-Fi provider. Settle Up & Quit stops monitoring and closes the app after confirmation."
                )
            }
            .padding(.trailing, 6)
        }
        .frame(maxHeight: 560)
    }
}

private struct HelpItem: View {
    let symbol: String
    let title: String
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(CoffeeTheme.caramel)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 10)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hide answer" : "Show answer")

            if isExpanded {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(CoffeeTheme.helpBody)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .padding(.top, 4)
                    .padding(.leading, 51)
            }
        }
    }
}
