import SwiftUI

/// Speed → coffee-roast tier. Beans fill left→right and darken as download
/// speed rises: `bean_count = 1 + (# of [5,15,50,100] thresholds met)`, capped
/// at 5. Lit bean i uses `roasts[i]` (bean 1 lightest, bean 5 darkest); the
/// tier badge uses the darkest lit bean's roast.
struct SpeedTier: Equatable {
    let count: Int
    let name: String
    let range: String
    let roast: Color

    static let roasts: [Color] = [
        Color(hex: 0xd09a55),
        Color(hex: 0xb3742f),
        Color(hex: 0x8a5623),
        Color(hex: 0x5f3a18),
        Color(hex: 0x3a2110),
    ]

    private static let names = ["Single", "Double", "Triple", "Quad", "Nitro"]
    private static let ranges = [
        "under 5 Mbps",
        "5–15 Mbps",
        "15–50 Mbps",
        "50–100 Mbps",
        "100+ Mbps",
    ]

    static func forDownload(_ download: Double) -> SpeedTier {
        let bounds: [Double] = [5, 15, 50, 100]
        let idx = min(4, bounds.filter { download >= $0 }.count)
        return SpeedTier(
            count: idx + 1,
            name: names[idx],
            range: ranges[idx],
            roast: roasts[idx]
        )
    }
}

private enum BeanPalette {
    static let unlitFill = Color(hex: 0xf1ece5)
    static let unlitStroke = Color(hex: 0xdcd3c8)
    static let unlitCrease = Color(hex: 0xe4dbd1)
}

/// Replaces the old speedometer + "Connection speed" + big number + "Test
/// Speed" row on the Status tab with the five-bean roast meter. Green stays the
/// connection signal; beans are the only speed signal, in a roast palette so the
/// two never read as the same light.
struct BeanMeterView: View {
    @ObservedObject var model: StatusModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var download: Double { model.beanDownloadMbps }
    private var hasReading: Bool { model.hasSpeedReading }
    private var tier: SpeedTier { .forDownload(download) }
    private var phase: SpeedTestPhase { model.isTestingCurrentConnection ? model.speedPhase : .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            bodyRow
            if model.isSpeedTesting, !model.isTestingCurrentConnection {
                Text("Finishing the previous connection’s speed check…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if !model.speedTestMessage.isEmpty, !model.isSpeedTesting {
                Text(model.speedTestMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // Badge appears once there is a real value to name — hidden while the beans
    // are pulsing through the measuring phase (no tier is known yet), shown as
    // it climbs during the reveal ramp and afterwards.
    private var showsBadge: Bool { hasReading && !model.isMeasuringSpeed }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Connection speed")
                .font(.system(size: 13, weight: .medium))

            if showsBadge {
                Text(tier.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tier.roast))
            }

            Spacer(minLength: 8)

            if !model.isTestingCurrentConnection, model.state.lastResult == "ONLINE" {
                Button("Test Speed") {
                    model.testSpeedAgain()
                }
                .buttonStyle(.quietCaramel)
                .disabled(model.isSpeedTesting)
            }
        }
    }

    private var bodyRow: some View {
        HStack(alignment: .center, spacing: 14) {
            BeanRow(
                litCount: hasReading ? tier.count : 0,
                measuring: model.isMeasuringSpeed,
                reduceMotion: reduceMotion
            )
            .frame(width: 148, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("↓ \(downloadLabel)")
                        .font(.system(size: 28, weight: .bold))
                        .monospacedDigit()
                    Text("Mbps")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                secondLine
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var secondLine: some View {
        switch phase {
        case .measuring:
            MeasuringStatusText(startedAt: model.speedTestStartedAt)
        case .revealing:
            Text("Finishing up…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .idle:
            if let measurement = model.connectionSpeedMeasurement {
                resultLine(measurement)
            } else {
                Text(model.state.lastResult == "ONLINE" ? "Not tested this connection" : "Available when online")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resultLine(_ measurement: SpeedMeasurement) -> some View {
        HStack(spacing: 0) {
            Text("↑ \(measurement.uploadSummary) Mbps")
                .foregroundStyle(.secondary)
            if let responsiveness = measurement.responsiveness {
                // Loaded-latency read (bufferbloat), the café-relevant signal.
                Text(" · \(responsiveness.label)")
                    .foregroundStyle(.secondary.opacity(0.75))
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var downloadLabel: String {
        if model.isMeasuringSpeed || !hasReading { return "—" }
        return SpeedMeasurement.format(download)
    }
}

/// The rotating "what's happening now" line shown while networkQuality runs.
/// Phases track the ~8s capped run: prepare → warm up → pour → finish.
private struct MeasuringStatusText: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: startedAt ?? .now, by: 0.25)) { context in
            let elapsed = startedAt.map {
                context.date.timeIntervalSince($0)
            } ?? 0
            Text(phrase(for: elapsed))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }

    private func phrase(for elapsed: TimeInterval) -> String {
        switch elapsed {
        case ..<2.0: "Preparing…"
        case ..<2.5: "Warming up…"
        case ..<5.0: "Pouring…"
        default: "Finishing up…"
        }
    }
}

/// Five beans in a row. Idle/reveal: lit beans use the roast ramp and pop on
/// over 0.25s. Measuring: beans sweep up and back down in a breathing wave while
/// the real value is unknown.
struct BeanRow: View {
    let litCount: Int
    var measuring = false
    var reduceMotion = false

    var body: some View {
        if measuring && !reduceMotion {
            PulsingBeans()
        } else {
            HStack(spacing: 7) {
                ForEach(0..<5, id: \.self) { i in
                    let on = i < litCount
                    BeanView(
                        fill: on ? SpeedTier.roasts[i] : BeanPalette.unlitFill,
                        stroke: on
                            ? SpeedTier.roasts[i]
                            : BeanPalette.unlitStroke,
                        crease: on ? .white : BeanPalette.unlitCrease,
                        creaseOpacity: on ? 0.82 : 0.9,
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
    }
}

/// The brewing animation: a triangle-wave "level" sweeps 0→5→0, so beans fill
/// left→right then drain right→left, over and over, until the value lands.
private struct PulsingBeans: View {
    private let period = 2.2

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: period) / period
            let triangle = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let level = triangle * 6

            HStack(spacing: 7) {
                ForEach(0..<5, id: \.self) { i in
                    let intensity = min(1, max(0, level - Double(i)))
                    ZStack {
                        BeanView(
                            fill: BeanPalette.unlitFill,
                            stroke: BeanPalette.unlitStroke,
                            crease: BeanPalette.unlitCrease,
                            creaseOpacity: 0.9,
                            reduceMotion: true
                        )
                        BeanView(
                            fill: SpeedTier.roasts[i],
                            stroke: SpeedTier.roasts[i],
                            crease: .white,
                            creaseOpacity: 0.82,
                            reduceMotion: true
                        )
                        .opacity(intensity)
                    }
                }
            }
        }
    }
}

private struct BeanView: View {
    let fill: Color
    let stroke: Color
    let crease: Color
    let creaseOpacity: Double
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(fill)
            Ellipse().stroke(stroke, lineWidth: 1.8)
            CreaseShape().stroke(
                crease.opacity(creaseOpacity),
                lineWidth: 1.6
            )
        }
        .frame(width: 18, height: 26)
        .rotationEffect(.degrees(-18))
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.25),
            value: fill
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.25),
            value: stroke
        )
    }
}

/// The white centre crease, matching the handoff SVG path
/// `M9 2 q4.5 11 0 22` in the bean's 18×26 design space.
private struct CreaseShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 18
        let sy = rect.height / 26
        var path = Path()
        path.move(to: CGPoint(x: 9 * sx, y: 2 * sy))
        path.addQuadCurve(
            to: CGPoint(x: 9 * sx, y: 24 * sy),
            control: CGPoint(x: 13.5 * sx, y: 13 * sy)
        )
        return path
    }
}

