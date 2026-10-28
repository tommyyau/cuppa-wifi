import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Everyday preferences") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Skip personal hotspots", isOn: Binding(
                        get: { model.preferences.ignorePersonalHotspots },
                        set: { model.setIgnorePersonalHotspots($0) }
                    ))
                    .disabled(model.persistentChangesDisabled)
                    Text("Skip sign-in checks on recognised iPhone and Android hotspots.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)

                    Toggle("Test speed after connecting", isOn: Binding(
                        get: { model.automaticSpeedTestsEnabled },
                        set: { model.setAutomaticSpeedTests($0) }
                    ))
                    .disabled(model.persistentChangesDisabled)
                    Text("Uses network data once per new connection. Turn off to use Test Speed only.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }
            Text("These switches save immediately. Pause automatic monitoring from Status.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Check every", selection: $model.preferences.interval) {
                        ForEach(MonitoringInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    Text("Short checks detect silent session expiry. Longer intervals reduce wakeups but take longer to notice it; network changes trigger a check separately.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = model.preferences.interval.energyNote {
                        Label(note, systemImage: "battery.50")
                            .font(.system(size: 10)).foregroundStyle(CoffeeTheme.warning)
                    }
                    Toggle("Allow a Wi-Fi reset after sign-in failures", isOn: $model.preferences.resetWiFiAfterFailures)
                        .toggleStyle(.switch)
                    Text("Off by default. This can interrupt other apps: after two failed sign-ins, Wi-Fi may briefly turn off and on, at most once every ten minutes. It cannot repair a venue’s internet service.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Apply advanced changes") { model.savePreferences() }
                            .buttonStyle(.caramelPrimary)
                            .disabled(!model.preferencesHaveUnsavedChanges || model.isBusy || model.isQuitting)
                        Button("Discard") { model.discardPreferenceChanges() }
                            .buttonStyle(.coffeeSecondary)
                            .disabled(!model.preferencesHaveUnsavedChanges || model.isBusy || model.isQuitting)
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))

            if !model.message.isEmpty {
                Text(model.message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .groupBoxStyle(CoffeeGroupBoxStyle())
    }
}
