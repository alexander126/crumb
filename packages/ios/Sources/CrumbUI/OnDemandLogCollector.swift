#if os(iOS)
import CrumbCore
import Foundation
import OSLog

enum OnDemandLogCollector {
    private static let scanLimit = 2_000
    private static let unifiedLogDeadline = DispatchTimeInterval.milliseconds(250)

    static func capture(options: CrumbLogOptions) -> CrumbLogDiagnostic {
        guard options.enabled else {
            return CrumbLogDiagnostic(
                status: .disabled,
                sources: [],
                entries: [],
                truncated: false,
                droppedEntryCount: 0,
                failures: []
            )
        }

        let capturedAt = Date()
        let earliest = capturedAt.addingTimeInterval(-options.lookback)
        var candidates: [CrumbLogEntry] = []
        var sources: [String] = []
        var failures: [String] = []
        var droppedBeforeBounding = 0

        if let unified = timeboxedUnifiedLogs(earliest: earliest) {
            candidates.append(contentsOf: unified.entries)
            droppedBeforeBounding += unified.dropped
            if let failure = unified.failure {
                failures.append(failure)
            } else {
                sources.append("os_log")
            }
        } else {
            failures.append("os_log_unavailable:timeout")
        }

        if let provider = options.provider {
            do {
                candidates.append(contentsOf: try provider.recentLogs())
                sources.append("host_provider")
            } catch {
                failures.append("host_provider_failed:\(String(describing: type(of: error)))")
            }
        }

        let bounded = bound(
            candidates,
            capturedAt: capturedAt,
            earliest: earliest,
            options: options,
            alreadyDropped: droppedBeforeBounding
        )
        let status: CrumbLogCaptureStatus
        if !bounded.entries.isEmpty {
            status = .captured
        } else if !sources.isEmpty {
            status = .empty
        } else {
            status = .unavailable
        }

        return CrumbLogDiagnostic(
            status: status,
            sources: Array(Set(sources)).sorted(),
            entries: bounded.entries,
            truncated: bounded.dropped > 0,
            droppedEntryCount: bounded.dropped,
            failures: failures
        )
    }

    private static func timeboxedUnifiedLogs(earliest: Date) -> UnifiedLogCapture? {
        let result = UnifiedLogCaptureBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(captureUnifiedLogs(earliest: earliest))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + unifiedLogDeadline) == .success else {
            return nil
        }
        return result.value
    }

    private static func captureUnifiedLogs(earliest: Date) -> UnifiedLogCapture {
        var entries: [CrumbLogEntry] = []
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // Start at the newest entry and stop once the configured window is
            // crossed. Forward enumeration from `earliest` can scan a large store
            // before reaching the evidence the report actually keeps.
            for case let entry as OSLogEntryLog in try store.getEntries(
                with: .reverse,
                at: nil,
                matching: nil
            ) {
                guard entry.date >= earliest else { break }
                entries.append(
                    CrumbLogEntry(
                        timestamp: entry.date,
                        level: level(entry.level),
                        source: "os_log",
                        category: [entry.subsystem, entry.category]
                            .filter { !$0.isEmpty }
                            .joined(separator: "/"),
                        message: entry.composedMessage
                    )
                )
                if entries.count >= scanLimit {
                    return UnifiedLogCapture(entries: entries, dropped: 1, failure: nil)
                }
            }
            return UnifiedLogCapture(entries: entries, dropped: 0, failure: nil)
        } catch {
            return UnifiedLogCapture(
                entries: [],
                dropped: 0,
                failure: "os_log_unavailable:\(String(describing: type(of: error)))"
            )
        }
    }

    private static func bound(
        _ entries: [CrumbLogEntry],
        capturedAt: Date,
        earliest: Date,
        options: CrumbLogOptions,
        alreadyDropped: Int
    ) -> (entries: [CrumbLogEntry], dropped: Int) {
        let futureTolerance = capturedAt.addingTimeInterval(5)
        let candidates = entries
            .filter { $0.timestamp >= earliest && $0.timestamp <= futureTolerance }
            .sorted { $0.timestamp > $1.timestamp }
        var selected: [CrumbLogEntry] = []
        var usedBytes = 0
        var dropped = alreadyDropped

        for entry in candidates {
            guard selected.count < options.maximumEntries else {
                dropped += 1
                continue
            }
            let sanitized = CrumbLogEntry(
                timestamp: entry.timestamp,
                level: entry.level,
                source: bounded(
                    CrumbLogSanitizer.sanitize(entry.source).isEmpty
                        ? "application"
                        : CrumbLogSanitizer.sanitize(entry.source),
                    length: 64
                ),
                category: bounded(CrumbLogSanitizer.sanitize(entry.category), length: 256),
                message: bounded(CrumbLogSanitizer.sanitize(entry.message), length: 65_536)
            )
            let byteCount = sanitized.source.utf8.count
                + sanitized.category.utf8.count
                + sanitized.message.utf8.count
                + 32
            guard usedBytes + byteCount <= options.maximumBytes else {
                dropped += 1
                continue
            }
            selected.append(sanitized)
            usedBytes += byteCount
        }

        return (selected.sorted { $0.timestamp < $1.timestamp }, dropped)
    }

    private static func bounded(_ value: String, length: Int) -> String {
        String(value.prefix(length))
    }

    private static func level(_ value: OSLogEntryLog.Level) -> CrumbLogLevel {
        switch value {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .error: .error
        case .fault: .fault
        case .undefined: .debug
        @unknown default: .debug
        }
    }
}

private struct UnifiedLogCapture: Sendable {
    let entries: [CrumbLogEntry]
    let dropped: Int
    let failure: String?
}

private final class UnifiedLogCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UnifiedLogCapture?

    var value: UnifiedLogCapture? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: UnifiedLogCapture) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
#endif
