import Foundation

/// Observe small filesystem metadata instead of repeatedly loading unchanged logs.
/// The file number also detects rotation/replacement with the same size and date.
struct FileChangeTracker {
    private struct Revision: Equatable {
        let modified: Date?
        let size: UInt64?
        let number: UInt64?

        init(_ url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes?[.modificationDate] as? Date
            size = (attributes?[.size] as? NSNumber)?.uint64Value
            number = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }
    private var previous: [Revision]?

    mutating func hasChanges(at urls: [URL]) -> Bool {
        let current = urls.map(Revision.init)
        guard previous != current else { return false }
        previous = current
        return true
    }
}
