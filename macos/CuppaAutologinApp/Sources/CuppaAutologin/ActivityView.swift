import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.state.lastResult == "ONLINE" {
                    connectionSummary
                } else if let diagnostics = model.portalDiagnostics {
                    PortalDiagnosticsView(record: diagnostics, compact: true)
                }
                if model.state.lastResult == "NO_NETWORK" {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(model.portalDiagnostics?.isActive(at: context.date) == true
                             ? "Network checks are running. The result and next action will appear here."
                             : model.serviceLoaded
                             ? "\(model.monitoringFactLabel): \(model.monitoringCountdown(at: context.date)). You can also use Check Now."
                             : "Automatic monitoring is paused. Use Check Now to retry.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Sign-ins, network problems and recoveries. Healthy routine checks stay quiet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if model.activity.isEmpty && model.diagnosticAttempts.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 30))
                            .foregroundStyle(CoffeeTheme.caramel)
                        Text("Quiet so far")
                            .font(.headline)
                        Text(
                            "Successful connections, portal detections, and automatic recoveries will appear here."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 210)
                } else if !model.activity.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.activity) { event in
                            ActivityRow(event: event)
                            if event.id != model.activity.last?.id {
                                Divider()
                                    .padding(.leading, 30)
                            }
                        }
                    }
                }

                DisclosureGroup("Troubleshooting") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Copy a summary when asking for help, or inspect a recorded attempt.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack {
                            Button("Copy support summary") { model.copySupportSummary() }
                            Menu("Open local files") {
                                Button("Portal captures…") { model.revealDiagnosticCaptures() }
                                Button("Raw log…") { model.revealRawLog() }
                            }
                        }
                        .buttonStyle(.coffeeSecondary)
                        .controlSize(.small)
                        Text("The summary includes network names. Raw files may also contain tokens and other identifiers. Review before sharing.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.diagnosticAttempts) { attempt in
                                AttemptTimeline(attempt: attempt, initiallyExpanded: false)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 11))

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 560)
        .onAppear {
            model.activityDidAppear()
        }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current connection")
                .font(.system(size: 11, weight: .semibold))
            Label("Connected successfully", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
            Text("Internet access is available on \(model.activityVenueDisplayName)")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            if model.isTestingCurrentConnection {
                Label("Checking connection quality…", systemImage: "speedometer")
                    .font(.system(size: 11, weight: .medium))
                Text("Measuring speed and responsiveness. This briefly uses network capacity.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.speedTestFailed {
                Text("Speed is unknown — the test could not finish. Internet access and connection quality are separate checks.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let speed = model.connectionSpeedMeasurement {
                Label(speed.hasQualityConcern ? "Connection quality is limited" : "Last speed check",
                      systemImage: speed.hasQualityConcern ? "exclamationmark.triangle" : "speedometer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(speed.hasQualityConcern ? .orange : .secondary)
                Text(speed.qualityMetrics).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Text(speed.hasQualityConcern
                     ? "Internet access is confirmed, but speed or responsiveness is limited. Repeating sign-in won’t improve this; try another network."
                     : speed.qualityAdvice)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Measured \(speed.measuredAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("Speed has not been measured for this connection. Internet access alone does not confirm a fast or steady connection.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let timestamp = model.state.lastConnectionTimestamp {
                Text("Connected at \(Date(timeIntervalSince1970: timestamp).formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CoffeeTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    private var color: Color {
        switch event.kind {
        case .success:
            .green
        case .attention:
            .orange
        case .information:
            .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .frame(width: 20)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(
                        event.occurredAt?.formatted(
                            date: .omitted,
                            time: .shortened
                        ) ?? event.timestamp
                    )
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(event.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }
}


private final class AttemptExpansion: ObservableObject {
    @Published var expanded: Bool
    @Published var showFields = false
    init(_ expanded: Bool) { self.expanded = expanded }
}

private struct AttemptTimeline: View {
    let attempt: DiagnosticAttempt
    @StateObject private var expansion: AttemptExpansion

    init(attempt: DiagnosticAttempt, initiallyExpanded: Bool) {
        self.attempt = attempt
        _expansion = StateObject(wrappedValue: AttemptExpansion(initiallyExpanded))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expansion.expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(attempt.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(CoffeeTheme.caramel)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(step.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(step.displayTime).font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(step.status == "running" && index < attempt.steps.count - 1 ? "done" : step.status)
                                    .font(.system(size: 10)).foregroundStyle(step.status == "fail" || step.status == "stopped" ? .red : CoffeeTheme.caramel)
                            }
                            Text(step.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            if !step.fields.isEmpty {
                                DisclosureGroup("Field interpretation", isExpanded: $expansion.showFields) {
                                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                                        GridRow {
                                            Text("Field seen"); Text("Interpretation / value used")
                                        }.font(.system(size: 10, weight: .semibold))
                                        ForEach(Array(step.fields.enumerated()), id: \.offset) { _, field in
                                            GridRow(alignment: .top) {
                                                Text("name: \(field.name)\nlabel: \(field.label)\nplaceholder: \(field.placeholder)\ntype: \(field.type)")
                                                Text("\(field.intent.uppercased())\n\(field.source)\n\(field.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? "Confidence unavailable")\n\(field.category) \(field.maskedValue)")
                                            }
                                        }
                                    }.font(.system(size: 10)).textSelection(.enabled)
                                }.font(.system(size: 11))
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Text(attempt.steps.last?.title ?? "Connection check")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(attempt.steps.first?.displayTime ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
