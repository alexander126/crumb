import CrumbCore
import Foundation
import Testing
@testable import CrumbUI

struct CrumbNewestLogWindowTests {
    private static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let lookback: TimeInterval = 60

    /// The defect this fixes: the collector asked for reverse enumeration and
    /// broke out of the loop at the first out-of-window entry. When the store
    /// enumerates oldest-first — which Apple documents it may do for this scope
    /// despite the reverse option — that break discarded every in-window entry.
    @Test
    func oldestFirstDeliveryStillRetainsTheInWindowEntries() {
        var window = newWindow(capacity: 10)
        let offered = [
            entry(secondsAgo: 600, message: "older than the window"),
            entry(secondsAgo: 300, message: "also older"),
            entry(secondsAgo: 30, message: "inside the window"),
            entry(secondsAgo: 5, message: "newest"),
        ]
        let legacySelection = Self.selectionWithABreakAtTheFirstOutOfWindowEntry(offered)

        offered.forEach { window.offer($0) }
        let captured = window.finish()

        #expect(legacySelection.isEmpty)
        #expect(captured.entries.map(\.message) == ["newest", "inside the window"])
        #expect(captured.evicted == 0)
    }

    @Test
    func newestFirstDeliveryRetainsTheSameEntries() {
        var window = newWindow(capacity: 10)
        let offered = [
            entry(secondsAgo: 5, message: "newest"),
            entry(secondsAgo: 30, message: "inside the window"),
            entry(secondsAgo: 300, message: "older"),
        ]

        offered.forEach { window.offer($0) }
        let captured = window.finish()

        #expect(captured.entries.map(\.message) == ["newest", "inside the window"])
        #expect(captured.evicted == 0)
    }

    @Test
    func anOutOfWindowEntryDoesNotEndTheScan() {
        var window = newWindow(capacity: 10)

        window.offer(entry(secondsAgo: 9_000, message: "ancient"))
        window.offer(entry(secondsAgo: 10, message: "kept"))
        let captured = window.finish()

        #expect(captured.entries.map(\.message) == ["kept"])
        #expect(captured.evicted == 0)
    }

    @Test
    func moreInWindowEntriesThanTheCapacityKeepTheNewest() {
        var window = newWindow(capacity: 3)
        for second in 1...40 {
            window.offer(entry(secondsAgo: TimeInterval(second), message: "entry-\(second)"))
        }

        let captured = window.finish()

        #expect(captured.entries.map(\.message) == ["entry-1", "entry-2", "entry-3"])
        #expect(captured.evicted == 37)
    }

    @Test
    func shuffledDeliveryStillKeepsTheNewest() {
        var window = newWindow(capacity: 3)
        for second in (1...40).shuffled() {
            window.offer(entry(secondsAgo: TimeInterval(second), message: "entry-\(second)"))
        }

        let captured = window.finish()

        #expect(Set(captured.entries.map(\.message)) == ["entry-1", "entry-2", "entry-3"])
        #expect(captured.evicted == 37)
    }

    @Test
    func aZeroCapacityWindowKeepsNothingAndReportsNoEviction() {
        var window = newWindow(capacity: 0)

        window.offer(entry(secondsAgo: 1, message: "newest"))
        let captured = window.finish()

        #expect(captured.entries.isEmpty)
        #expect(captured.evicted == 0)
    }

    private func newWindow(capacity: Int) -> CrumbNewestLogWindow {
        CrumbNewestLogWindow(
            capacity: capacity,
            earliest: Self.capturedAt.addingTimeInterval(-Self.lookback)
        )
    }

    private func entry(secondsAgo: TimeInterval, message: String) -> CrumbLogEntry {
        CrumbLogEntry(
            timestamp: Self.capturedAt.addingTimeInterval(-secondsAgo),
            level: .info,
            source: "os_log",
            category: "synthetic",
            message: message
        )
    }

    /// Reproduces the pre-fix selection rule so the regression stays visible in
    /// the suite rather than only in the commit message.
    private static func selectionWithABreakAtTheFirstOutOfWindowEntry(
        _ offered: [CrumbLogEntry]
    ) -> [CrumbLogEntry] {
        let earliest = capturedAt.addingTimeInterval(-lookback)
        var selected: [CrumbLogEntry] = []
        for entry in offered {
            guard entry.timestamp >= earliest else { break }
            selected.append(entry)
        }
        return selected
    }
}
