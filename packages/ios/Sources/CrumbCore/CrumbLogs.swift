import Foundation

public enum CrumbLogLevel: String, Equatable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault
}

public struct CrumbLogEntry: Equatable, Sendable {
    public let timestamp: Date
    public let level: CrumbLogLevel
    public let source: String
    public let category: String
    public let message: String

    public init(
        timestamp: Date,
        level: CrumbLogLevel,
        source: String = "application",
        category: String,
        message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.category = category
        self.message = message
    }
}

/// Supplies already-buffered application logs when a report is explicitly opened.
/// Implementations must be thread-safe and return promptly from an in-memory snapshot.
public protocol CrumbLogProvider: AnyObject, Sendable {
    func recentLogs() throws -> [CrumbLogEntry]
}

public struct CrumbLogOptions: Equatable, Sendable {
    public let enabled: Bool
    public let lookback: TimeInterval
    public let maximumEntries: Int
    public let maximumBytes: Int
    public let provider: (any CrumbLogProvider)?

    public init(
        enabled: Bool = true,
        lookback: TimeInterval = 60,
        maximumEntries: Int = 200,
        maximumBytes: Int = 65_536,
        provider: (any CrumbLogProvider)? = nil
    ) {
        self.enabled = enabled
        self.lookback = lookback
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
        self.provider = provider
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        let sameProvider: Bool
        switch (lhs.provider, rhs.provider) {
        case (nil, nil):
            sameProvider = true
        case let (lhsProvider?, rhsProvider?):
            sameProvider = lhsProvider === rhsProvider
        default:
            sameProvider = false
        }

        return lhs.enabled == rhs.enabled
            && lhs.lookback == rhs.lookback
            && lhs.maximumEntries == rhs.maximumEntries
            && lhs.maximumBytes == rhs.maximumBytes
            && sameProvider
    }
}

public enum CrumbLogCaptureStatus: String, Equatable, Sendable {
    case captured
    case empty
    case unavailable
    case disabled
}

public struct CrumbLogDiagnostic: Equatable, Sendable {
    public let status: CrumbLogCaptureStatus
    public let sources: [String]
    public let entries: [CrumbLogEntry]
    public let truncated: Bool
    public let droppedEntryCount: Int
    public let failures: [String]

    public init(
        status: CrumbLogCaptureStatus,
        sources: [String],
        entries: [CrumbLogEntry],
        truncated: Bool,
        droppedEntryCount: Int,
        failures: [String]
    ) {
        self.status = status
        self.sources = sources
        self.entries = entries
        self.truncated = truncated
        self.droppedEntryCount = droppedEntryCount
        self.failures = failures
    }
}

package enum CrumbLogSanitizer {
    package static func sanitize(_ value: String) -> String {
        var sanitized = value
        let replacements = [
            (#"(?i)(https?://)[^/\s:@]+:[^/@\s]+@"#, "$1[REDACTED]@"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
            (
                #"(?i)\b(authorization|cookie|set-cookie|password|passwd|secret|token|api[_-]?key)\s*[:=]\s*(\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
                "$1=[REDACTED]"
            ),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[REDACTED_EMAIL]"),
            (#"\b(?:\d[ -]*?){13,19}\b"#, "[REDACTED_NUMBER]"),
            (#"([?&][A-Za-z0-9._~-]+)=([^&#\s]*)"#, "$1=[REDACTED]"),
            (#"[\u0000-\u001F\u007F]"#, " ")
        ]

        for (pattern, replacement) in replacements {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return sanitized
    }
}
