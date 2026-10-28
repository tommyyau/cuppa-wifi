import SwiftUI

struct StatusView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader
            facts
            actions
            if ["CAPTIVE", "NO_NETWORK", "UNKNOWN", "UNSUPPORTED"].contains(model.state.lastResult), let diagnostics = model.portalDiagnostics {
                PortalDiagnosticsView(record: diagnostics, compact: true)
            }

            if !model.message.isEmpty {
                Text(model.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
            }

            Divider()
            speed
            Divider()
            quitFooter
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            StatusCupIcon(state: model.statusCupState)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusTitle)
                    .font(.system(size: 18, weight: .bold))
                Text(model.statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if model.needsNetworkNameAccess {
                    Button("Show Wi-Fi name") {
                        model.requestNetworkNameAccess()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CoffeeTheme.caramelLink)
                    .font(.system(size: 10))
                }
            }

            Spacer(minLength: 8)

            if model.showsAttemptProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var facts: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Grid(
                alignment: .leading,
                horizontalSpacing: 16,
                verticalSpacing: 6
            ) {
                GridRow {
                    Text("Time connected")
                        .foregroundStyle(.secondary)
                    Text(model.timeConnected(at: context.date))
                        .monospacedDigit()
                }
                GridRow {
                    Text(model.monitoringFactLabel)
                        .foregroundStyle(.secondary)
                    Text(model.monitoringCountdown(at: context.date))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13))
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button("Check Now") {
                    model.checkNow()
                }
                .buttonStyle(.caramelPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.checkNowIsDisabled)

                Spacer()

                Text("Auto monitoring")
                    .font(.system(size: 12))
                Toggle(
                    "Auto monitoring",
                    isOn: Binding(
                        get: { model.monitoringEnabled },
                        set: { model.setMonitoringEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isBusy || model.isQuitting)
            }

            if model.canFinishPortal {
                Button("Finish sign-in") { model.finishPortalManually() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || model.isQuitting || model.activeOperation != nil)
            }

            if let reason = model.checkNowDisabledReason {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .controlSize(.small)
    }

    private var speed: some View {
        BeanMeterView(model: model)
    }

    private var quitFooter: some View {
        HStack(spacing: 8) {
            Text("Done for today?")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                model.presentQuitReceipt()
            } label: {
                Label {
                    Text("Settle Up & Quit…")
                } icon: {
                    ReceiptIcon()
                        .frame(width: 11, height: 13)
                }
            }
            .buttonStyle(.quietCaramel)
        }
    }
}
