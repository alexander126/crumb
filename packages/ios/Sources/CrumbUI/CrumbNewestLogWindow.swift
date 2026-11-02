import CrumbCore
import Foundation

/// Collects the newest log entries inside a lookback window while making no
/// assumption about the order in which they arrive.
///
/// `OSLogStore.getEntries(with:at:matching:)` accepts `.reverse` but is
/// documented not to honor it for the current-process scope, so a collector
/// that stops at the first out-of-window entry can keep nothing at all on a
/// long-running process. Entries outside the window are therefore skipped
/// rather than treated as a stop condition, and the retained set is pruned by
/// timestamp so the newest entries survive regardless of arrival order.
///
/// Free of `OSLog` so the retention rule is testable on any host.
struct CrumbNewestLogWindow {
    private let capacity: Int
    private let earliest: Date
    private var retained: [CrumbLogEntry] = []
    private var evictedEntryCount = 0

    init(capacity: Int, earliest: Date) {
        self.capacity = max(capacity, 0)
        self.earliest = earliest
    }

    /// Offers one entry. Entries older than the window are skipped; they are
    /// not evidence loss and must not stop the enumeration.
    mutating func offer(_ entry: CrumbLogEntry) {
        guard capacity > 0, entry.timestamp >= earliest else { return }
        retained.append(entry)
        // Prune in batches so eviction stays amortized rather than scanning the
        // retained set for every entry a busy store delivers.
        if retained.count >= capacity * 2 {
            prune()
        }
    }

    /// The retained entries, newest first, with the number of in-window entries
    /// that had to be evicted to stay inside `capacity`.
    mutating func finish() -> (entries: [CrumbLogEntry], evicted: Int) {
        prune()
        retained.sort { $0.timestamp > $1.timestamp }
        return (retained, evictedEntryCount)
    }

    private mutating func prune() {
        guard retained.count > capacity else { return }
        evictedEntryCount += retained.count - capacity
        retained = Array(retained.sorted { $0.timestamp > $1.timestamp }.prefix(capacity))
    }
}
