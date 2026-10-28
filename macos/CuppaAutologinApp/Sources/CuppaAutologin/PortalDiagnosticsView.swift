import SwiftUI

struct PortalDiagnosticsView: View {
    let record: PortalDiagnostics
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let active = record.isActive(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(active ? "Live connection check" : "Most recent connection check")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if active { ProgressView().controlSize(.mini) }
                }
                Text(!record.terminal && !active ? "Attempt ended — waiting for the next connection check" : record.title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(compact ? "\(record.elapsed(at: context.date)) seconds elapsed" : record.phase.hasPrefix("network")
                     ? "\(record.elapsed(at: context.date))s elapsed · No sign-in form reached"
                     : "\(record.elapsed(at: context.date))s elapsed · \(record.actions) actions · \(record.navigations) pages · \(record.reasoningRequests) model passes")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.secondary)
                if !compact {
                    if let reason = record.reason, record.detail == nil {
                        Text("Reason: \(reason.replacingOccurrences(of: "_", with: " "))\(record.failureCode.map { " (error \($0))" } ?? "")")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(record.events.suffix(5).enumerated()), id: \.offset) { _, event in
                        Text("\(Int(max(0, event.time - record.startedAt)))s  \(event.title)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CoffeeTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
        }
    }
}
