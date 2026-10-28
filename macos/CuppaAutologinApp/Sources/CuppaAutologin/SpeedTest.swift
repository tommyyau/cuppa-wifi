import Foundation

struct SpeedMeasurement: Codable, Equatable, Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    let latencyMilliseconds: Double?
    let measuredAt: Date
    let gatewayMac: String?
    /// Apple's responsiveness score in round-trips-per-minute (RPM), measured
    /// under load — the bufferbloat signal that predicts whether calls/streams
    /// stutter. Optional so measurements stored before this field decode cleanly.
    var responsivenessRpm: Double?

    var compactSummary: String {
        "↓ \(Self.format(downloadMbps))  ↑ \(Self.format(uploadMbps)) Mbps"
    }

    var uploadSummary: String {
        Self.format(uploadMbps)
    }

    static func format(_ value: Double) -> String {
        if value < 10 {
            return value.formatted(.number.precision(.fractionLength(1)))
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// Human read of the responsiveness (RPM) score, using Apple's own bands:
/// <100 Low, 100–450 Medium, >450 High.
enum Responsiveness: Equatable {
    case smooth
    case steady
    case laggy

    init(rpm: Double) {
        switch rpm {
        case 450...: self = .smooth
        case 100...: self = .steady
        default: self = .laggy
        }
    }

    var label: String {
        switch self {
        case .smooth: "Smooth"
        case .steady: "Steady"
        case .laggy: "Laggy"
        }
    }
}

extension SpeedMeasurement {
    var responsiveness: Responsiveness? {
        responsivenessRpm.map(Responsiveness.init(rpm:))
    }

    // Product guidance, not a diagnosis of signal strength or the venue's ISP.
    var hasQualityConcern: Bool {
        downloadMbps < 5 || responsiveness == .laggy || (latencyMilliseconds ?? 0) >= 300
    }

    var qualityAdvice: String {
        var advice: [String] = []
        if downloadMbps < 5 { advice.append("Limited download speed: larger pages and downloads may take longer.") }
        if responsiveness == .laggy { advice.append("Low responsiveness under load: calls and browsing may lag when busy.") }
        if (latencyMilliseconds ?? 0) >= 300 { advice.append("High idle latency: requests may respond slowly.") }
        if !advice.isEmpty {
            advice.append("Internet access is confirmed; repeating sign-in will not improve this. Try another network if it is too slow.")
        } else {
            advice.append("This is a snapshot of speed, not a guarantee of steady access.")
        }
        return advice.joined(separator: " ")
    }

    var qualityMetrics: String {
        var parts = [compactSummary]
        if let latencyMilliseconds { parts.append("\(Int(latencyMilliseconds.rounded())) ms idle latency") }
        if let responsivenessRpm { parts.append("\(Int(responsivenessRpm.rounded())) RPM under load") }
        return parts.joined(separator: " · ")
    }
}

enum SpeedTestError: LocalizedError {
    case unavailable
    case commandFailed(String)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "macOS network quality testing is unavailable"
        case let .commandFailed(detail):
            detail.isEmpty ? "The speed test could not finish" : detail
        case .invalidResult:
            "macOS returned an incomplete speed-test result"
        }
    }
}

enum SpeedTestOutcome: Sendable {
    case success(SpeedMeasurement)
    case failure(String)
}

enum SpeedTestRunner {
    private struct NetworkQualityPayload: Decodable {
        let downloadBitsPerSecond: Double
        let uploadBitsPerSecond: Double
        let baseRTT: Double?
        let responsiveness: Double?

        enum CodingKeys: String, CodingKey {
            case downloadBitsPerSecond = "dl_throughput"
            case uploadBitsPerSecond = "ul_throughput"
            case baseRTT = "base_rtt"
            case responsiveness
        }
    }

    static func parse(
        _ data: Data,
        gatewayMac: String?,
        measuredAt: Date = Date()
    ) throws -> SpeedMeasurement {
        let payload: NetworkQualityPayload
        do {
            payload = try JSONDecoder().decode(
                NetworkQualityPayload.self,
                from: data
            )
        } catch {
            throw SpeedTestError.invalidResult
        }
        guard payload.downloadBitsPerSecond >= 0,
              payload.uploadBitsPerSecond >= 0
        else {
            throw SpeedTestError.invalidResult
        }
        return SpeedMeasurement(
            downloadMbps: payload.downloadBitsPerSecond / 1_000_000,
            uploadMbps: payload.uploadBitsPerSecond / 1_000_000,
            latencyMilliseconds: payload.baseRTT,
            measuredAt: measuredAt,
            gatewayMac: gatewayMac,
            responsivenessRpm: payload.responsiveness
        )
    }

    static func run(
        interface: String = "en0",
        gatewayMac: String?
    ) throws -> SpeedMeasurement {
        guard FileManager.default.isExecutableFile(
            atPath: "/usr/bin/networkQuality"
        ) else {
            throw SpeedTestError.unavailable
        }
        let result = ProcessRunner.run(
            "/usr/bin/networkQuality",
            ["-c", "-I", interface, "-M", "8"],
            timeout: 30
        )
        if result.status == 124 {
            throw SpeedTestError.commandFailed("Speed test timed out after 30 seconds")
        }
        guard result.status == 0 else {
            throw SpeedTestError.commandFailed(
                result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try parse(
            Data(result.output.utf8),
            gatewayMac: gatewayMac
        )
    }

    static func outcome(
        interface: String = "en0",
        gatewayMac: String?
    ) -> SpeedTestOutcome {
        do {
            return .success(
                try run(interface: interface, gatewayMac: gatewayMac)
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

enum SpeedMeasurementStore {
    private static let measurementKey = "lastSpeedMeasurement"
    private static let automaticConnectionKey =
        "lastAutomaticSpeedTestConnectionTimestamp"

    static func load(for gatewayMac: String?) -> SpeedMeasurement? {
        guard let data = UserDefaults.standard.data(
            forKey: measurementKey
        ),
        let measurement = try? JSONDecoder().decode(
            SpeedMeasurement.self,
            from: data
        ),
        measurement.gatewayMac == gatewayMac
        else {
            return nil
        }
        return measurement
    }

    static func save(_ measurement: SpeedMeasurement) {
        guard let data = try? JSONEncoder().encode(measurement) else {
            return
        }
        UserDefaults.standard.set(data, forKey: measurementKey)
    }

    static var lastAutomaticConnectionTimestamp: TimeInterval? {
        get {
            guard UserDefaults.standard.object(
                forKey: automaticConnectionKey
            ) != nil else {
                return nil
            }
            return UserDefaults.standard.double(
                forKey: automaticConnectionKey
            )
        }
        set {
            if let newValue {
                UserDefaults.standard.set(
                    newValue,
                    forKey: automaticConnectionKey
                )
            } else {
                UserDefaults.standard.removeObject(
                    forKey: automaticConnectionKey
                )
            }
        }
    }
}
