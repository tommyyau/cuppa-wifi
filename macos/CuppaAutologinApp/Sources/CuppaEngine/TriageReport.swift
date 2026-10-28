import CuppaCore
import Foundation

/// Read-only, human-readable access to private v1 and v2 diagnostic evidence.
/// The timeline uses capture timestamps, so copying an archive does not reorder it.
public struct TriageReport: Sendable {
    public let paths: EnginePaths
    public init(paths: EnginePaths) { self.paths = paths }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
    private func captured(_ url: URL) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: String(url.lastPathComponent.prefix(16))) ?? modified(url)
    }
    private func children(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]))
            ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { captured($0) > captured($1) }
    }
    private func match(_ expression: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: expression),
            let result = regex.firstMatch(
                in: value, range: NSRange(value.startIndex..., in: value)),
            let range = Range(result.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }
    private func names(in lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var recent: (name: String, index: Int)?
        for (index, line) in lines.enumerated() {
            if let name = match("portal venue identified:\\s*(.+?)\\s*$", in: line) {
                recent = (name, index)
            }
            if let fingerprint = match("/captures/([^/\\s]+)/", in: line), let recent,
                index - recent.index <= 10
            {
                result[fingerprint] = recent.name
            }
        }
        return result
    }

    public func render(selector: String?) -> String {
        let venues = children(paths.captures)
        guard !venues.isEmpty else { return "No captured venues yet — nothing to triage." }
        let logLines = ((try? String(contentsOf: paths.log, encoding: .utf8)) ?? "").components(
            separatedBy: .newlines)
        let venueNames = names(in: logLines)
        let rows = venues.compactMap { venue -> (venue: URL, capture: URL)? in
            guard let capture = children(venue).first else { return nil }
            return (venue, capture)
        }.sorted { captured($0.capture) > captured($1.capture) }
        guard let selector, !selector.isEmpty else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var lines = ["Recent captured failures (newest first, local time):"]
            for row in rows.prefix(15) {
                let diagnostic =
                    PrivateFile.object(at: row.capture.appendingPathComponent("diagnostic.json"))
                    ?? [:]
                let reason =
                    diagnostic["failure_reason"] as? String ?? diagnostic["outcome"] as? String
                    ?? "captured"
                lines.append(
                    "\(formatter.string(from: captured(row.capture)))  \(venueNames[row.venue.lastPathComponent] ?? "(venue name unknown)")  \(reason)  [\(row.venue.lastPathComponent)]"
                )
            }
            lines.append("Drill in with --triage <venue name, fingerprint, or latest>.")
            return lines.joined(separator: "\n")
        }
        let needle = EvidenceStore.safeKey(selector).lowercased()
        let venue =
            needle == "latest"
            ? rows.first?.venue
            : rows.first {
                $0.venue.lastPathComponent.lowercased().contains(needle)
                    || venueNames[$0.venue.lastPathComponent]?.localizedCaseInsensitiveContains(
                        selector) == true
            }?.venue
        guard let venue else {
            return "No venue matched. Known venues:\n"
                + rows.map { $0.venue.lastPathComponent }.joined(separator: "\n")
        }
        var lines = [
            "Triage report: " + venue.lastPathComponent,
            "Raw private evidence; review before sharing.",
        ]
        if let name = venueNames[venue.lastPathComponent] { lines.append("Venue: " + name) }
        if let capture = children(venue).first {
            lines.append("Capture: " + capture.path)
            if let diagnostic = PrivateFile.object(
                at: capture.appendingPathComponent("diagnostic.json"))
            {
                for key in ["outcome", "failure_reason"] {
                    if let value = diagnostic[key] { lines.append("\(key): \(value)") }
                }
            }
            if let data = try? Data(contentsOf: capture.appendingPathComponent("manifest.json")),
                let hops = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            {
                for hop in hops {
                    lines.append(
                        "\(hop["method"] ?? "GET") \(hop["url"] ?? "") → \(hop["status"] ?? "unavailable")"
                    )
                }
            }
            let bodies =
                ((try? FileManager.default.contentsOfDirectory(
                    at: capture, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .filter { $0.lastPathComponent.hasSuffix("_body.html") }.sorted {
                    $0.lastPathComponent < $1.lastPathComponent
                }
            for body in bodies.prefix(24) {
                guard let handle = try? FileHandle(forReadingFrom: body) else { continue }
                let bytes = try? handle.read(upToCount: 524_288)
                try? handle.close()
                let text = bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                if ["validationfielderror", "\"success\":false", "\"error\"", "invem"].contains(
                    where: { text.lowercased().contains($0) })
                {
                    lines.append(
                        body.lastPathComponent + ": "
                            + text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
                }
            }
        }
        if let forensic = children(paths.forensics.appendingPathComponent(venue.lastPathComponent))
            .first
        {
            lines.append("Forensics: " + forensic.path)
            if let summary = PrivateFile.object(at: forensic.appendingPathComponent("summary.json"))
            {
                for key in [
                    "gateway_ip", "http_intercepted_to", "portal_final_url", "notes", "errors",
                ] { if let value = summary[key] { lines.append("\(key): \(value)") } }
            }
        }
        lines += logLines.filter { $0.contains(venue.lastPathComponent) }.suffix(40)
        return lines.joined(separator: "\n")
    }
}
