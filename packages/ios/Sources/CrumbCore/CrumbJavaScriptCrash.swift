import CryptoKit
import Foundation

public enum CrumbJavaScriptCrashKind: String, Codable, Equatable, Sendable {
    case fatalException = "fatal_exception"
    case unhandledRejection = "unhandled_rejection"
}

public enum CrumbJavaScriptCrashSource: String, Codable, Equatable, Sendable {
    case javascript
    case nativeTerminationWrapper = "native_termination_wrapper"
}

public struct CrumbJavaScriptBreadcrumb: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let category: String
    public let message: String

    public init(timestamp: Date, category: String, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

public struct CrumbJavaScriptCrash: Codable, Equatable, Sendable {
    public let kind: CrumbJavaScriptCrashKind
    public let source: CrumbJavaScriptCrashSource
    public let errorType: String
    public let message: String
    public let rawStack: String?
    public let fingerprint: String?
    public let occurredAt: Date
    public let nativeTerminationWrapper: Bool
    public let breadcrumbs: [CrumbJavaScriptBreadcrumb]

    public init(
        kind: CrumbJavaScriptCrashKind,
        source: CrumbJavaScriptCrashSource = .javascript,
        errorType: String,
        message: String,
        rawStack: String? = nil,
        fingerprint: String? = nil,
        occurredAt: Date = Date(),
        nativeTerminationWrapper: Bool = false,
        breadcrumbs: [CrumbJavaScriptBreadcrumb] = []
    ) {
        self.kind = kind
        self.source = source
        self.errorType = errorType
        self.message = message
        self.rawStack = rawStack
        self.fingerprint = fingerprint
        self.occurredAt = occurredAt
        self.nativeTerminationWrapper = nativeTerminationWrapper
        self.breadcrumbs = breadcrumbs
    }
}

package struct CrumbJavaScriptCrashRecord: Codable, Equatable, Sendable {
    package let reportID: String
    package let appVersion: String
    package let nativeBuild: String
    package let bundleVersion: String?
    package let environment: String
    package let applicationName: String?
    package let customContext: [String: String]
    package let policyStatus: String
    package let workspacePolicyVersion: Int?
    package let crash: CrumbJavaScriptCrash

    package init(
        reportID: String,
        settings: CrumbReportSettings,
        crash: CrumbJavaScriptCrash
    ) {
        self.reportID = reportID
        appVersion = settings.release.appVersion
        nativeBuild = settings.release.nativeBuild
        bundleVersion = settings.release.bundleVersion
        environment = settings.environment
        applicationName = settings.application.name
        customContext = settings.customContext
        policyStatus = settings.policyStatus.rawValue
        workspacePolicyVersion = settings.workspacePolicyVersion
        self.crash = crash
    }
}

/// Synchronously persists only the small, sanitized crash handoff. It is
/// separate from the report queue because JavaScript fatal handlers must not
/// wait for an actor or a report envelope to be assembled.
package final class CrumbJavaScriptCrashStore: @unchecked Sendable {
    package static let shared = CrumbJavaScriptCrashStore(rootURL: defaultRootURL())

    package static let maximumRecords = 8
    package static let maximumFileBytes = 262_144
    package static let maximumBreadcrumbs = 32
    package static let maximumBreadcrumbBytes = 16_384

    private let lock = NSLock()
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    @discardableResult
    package func record(
        _ crash: CrumbJavaScriptCrash,
        settings: CrumbReportSettings
    ) -> Bool {
        guard let normalized = normalize(crash) else { return false }
        return withLock {
            var records = readRecords()
            let incoming = CrumbJavaScriptCrashRecord(
                reportID: CrumbReportEnvelopeBuilder.makeReportID(),
                settings: settings,
                crash: normalized
            )
            if let index = records.firstIndex(where: {
                $0.crash.fingerprint == normalized.fingerprint
            }) {
                records[index] = merge(records[index], incoming)
            } else {
                guard records.count < Self.maximumRecords else { return false }
                records.append(incoming)
            }
            return writeRecords(records)
        }
    }

    package func records() -> [CrumbJavaScriptCrashRecord] {
        withLock { readRecords() }
    }

    @discardableResult
    package func remove(reportID: String) -> Bool {
        withLock {
            var records = readRecords()
            let originalCount = records.count
            records.removeAll { $0.reportID == reportID }
            guard records.count != originalCount else { return true }
            return writeRecords(records)
        }
    }

    private func normalize(_ crash: CrumbJavaScriptCrash) -> CrumbJavaScriptCrash? {
        guard crash.occurredAt.timeIntervalSince1970.isFinite else { return nil }
        let errorType = sanitize(crash.errorType, maximumBytes: 128)
        let message = sanitize(crash.message, maximumBytes: 4_096)
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let rawStack = crash.rawStack
            .map { sanitize($0, maximumBytes: 16_384, preserveLineBreaks: true) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let normalizedBreadcrumbs = crash.breadcrumbs.compactMap { breadcrumb -> CrumbJavaScriptBreadcrumb? in
            guard breadcrumb.timestamp.timeIntervalSince1970.isFinite else { return nil }
            let category = sanitize(breadcrumb.category, maximumBytes: 64)
            let message = sanitize(breadcrumb.message, maximumBytes: 2_048)
            guard !category.isEmpty, !message.isEmpty else { return nil }
            return CrumbJavaScriptBreadcrumb(
                timestamp: breadcrumb.timestamp,
                category: category,
                message: message
            )
        }
        var breadcrumbBytes = 0
        let boundedBreadcrumbs = normalizedBreadcrumbs.suffix(Self.maximumBreadcrumbs).filter { breadcrumb in
            let bytes = breadcrumb.category.utf8.count + breadcrumb.message.utf8.count + 32
            guard breadcrumbBytes + bytes <= Self.maximumBreadcrumbBytes else { return false }
            breadcrumbBytes += bytes
            return true
        }

        let fingerprint = normalizedFingerprint(
            supplied: crash.fingerprint,
            kind: crash.kind,
            errorType: errorType.isEmpty ? "JavaScriptError" : errorType,
            message: message,
            rawStack: rawStack
        )
        let source = crash.source
        return CrumbJavaScriptCrash(
            kind: crash.kind,
            source: source,
            errorType: errorType.isEmpty ? "JavaScriptError" : errorType,
            message: message,
            rawStack: rawStack,
            fingerprint: fingerprint,
            occurredAt: crash.occurredAt,
            nativeTerminationWrapper: crash.nativeTerminationWrapper || source == .nativeTerminationWrapper,
            breadcrumbs: Array(boundedBreadcrumbs)
        )
    }

    private func merge(
        _ existing: CrumbJavaScriptCrashRecord,
        _ incoming: CrumbJavaScriptCrashRecord
    ) -> CrumbJavaScriptCrashRecord {
        let javascript = if incoming.crash.source == .javascript {
            incoming.crash
        } else if existing.crash.source == .javascript {
            existing.crash
        } else {
            incoming.crash
        }
        let source: CrumbJavaScriptCrashSource = if existing.crash.source == .javascript
            || incoming.crash.source == .javascript {
            .javascript
        } else {
            .nativeTerminationWrapper
        }
        let breadcrumbs = mergeBreadcrumbs(existing.crash.breadcrumbs, incoming.crash.breadcrumbs)
        let crash = CrumbJavaScriptCrash(
            kind: javascript.kind,
            source: source,
            errorType: javascript.errorType,
            message: javascript.message,
            rawStack: javascript.rawStack ?? existing.crash.rawStack ?? incoming.crash.rawStack,
            fingerprint: javascript.fingerprint,
            occurredAt: min(existing.crash.occurredAt, incoming.crash.occurredAt),
            nativeTerminationWrapper: existing.crash.nativeTerminationWrapper
                || incoming.crash.nativeTerminationWrapper
                || source == .nativeTerminationWrapper,
            breadcrumbs: breadcrumbs
        )
        return CrumbJavaScriptCrashRecord(
            reportID: existing.reportID,
            appVersion: existing.appVersion,
            nativeBuild: existing.nativeBuild,
            bundleVersion: existing.bundleVersion,
            environment: existing.environment,
            applicationName: existing.applicationName,
            customContext: existing.customContext,
            policyStatus: existing.policyStatus,
            workspacePolicyVersion: existing.workspacePolicyVersion,
            crash: crash
        )
    }

    private func mergeBreadcrumbs(
        _ first: [CrumbJavaScriptBreadcrumb],
        _ second: [CrumbJavaScriptBreadcrumb]
    ) -> [CrumbJavaScriptBreadcrumb] {
        var result: [CrumbJavaScriptBreadcrumb] = []
        for breadcrumb in (first + second).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !result.contains(breadcrumb) else { continue }
            let bytes = result.reduce(0) { $0 + $1.category.utf8.count + $1.message.utf8.count + 32 }
                + breadcrumb.category.utf8.count + breadcrumb.message.utf8.count + 32
            guard result.count < Self.maximumBreadcrumbs else { break }
            guard bytes <= Self.maximumBreadcrumbBytes else { continue }
            result.append(breadcrumb)
        }
        return result
    }

    private func normalizedFingerprint(
        supplied: String?,
        kind: CrumbJavaScriptCrashKind,
        errorType: String,
        message: String,
        rawStack: String?
    ) -> String {
        if let supplied,
           supplied.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil {
            return supplied
        }
        let value = "\(kind.rawValue)|\(errorType)|\(message)|\(rawStack ?? "")"
        let digest = SHA256.hash(data: Data(value.utf8))
        return "js_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func readRecords() -> [CrumbJavaScriptCrashRecord] {
        guard let data = try? Data(contentsOf: fileURL), data.count <= Self.maximumFileBytes else {
            return []
        }
        return (try? decoder.decode([CrumbJavaScriptCrashRecord].self, from: data)) ?? []
    }

    private func writeRecords(_ records: [CrumbJavaScriptCrashRecord]) -> Bool {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try applyStorageAttributes(to: rootURL)
            let data = try encoder.encode(records)
            guard data.count <= Self.maximumFileBytes else { return false }
            try data.write(to: fileURL, options: [.atomic])
            try applyStorageAttributes(to: fileURL)
            return true
        } catch {
            return false
        }
    }

    private var fileURL: URL {
        rootURL.appendingPathComponent("pending-javascript-crashes.json")
    }

    private func sanitize(
        _ value: String,
        maximumBytes: Int,
        preserveLineBreaks: Bool = false
    ) -> String {
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
            (#"([?&][A-Za-z0-9._~-]+)=([^&#\s]*)"#, "$1=[REDACTED]")
        ]
        for (pattern, replacement) in replacements {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        sanitized = sanitized.unicodeScalars.reduce(into: "") { result, scalar in
            if preserveLineBreaks && (scalar == "\n" || scalar == "\r") {
                result.append(Character(scalar))
            } else if CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{7f}" {
                result.append(" ")
            } else {
                result.append(Character(scalar))
            }
        }
        return truncateUTF8(sanitized.trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: maximumBytes)
    }

    private func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        for character in value {
            let candidate = result + String(character)
            if candidate.utf8.count + 3 > maximumBytes { break }
            result = candidate
        }
        return result + "…"
    }

    private func withLock<Result>(_ action: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }

    private func applyStorageAttributes(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func defaultRootURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.crumb", isDirectory: true)
    }
}

private extension CrumbJavaScriptCrashRecord {
    init(
        reportID: String,
        appVersion: String,
        nativeBuild: String,
        bundleVersion: String?,
        environment: String,
        applicationName: String?,
        customContext: [String: String],
        policyStatus: String,
        workspacePolicyVersion: Int?,
        crash: CrumbJavaScriptCrash
    ) {
        self.reportID = reportID
        self.appVersion = appVersion
        self.nativeBuild = nativeBuild
        self.bundleVersion = bundleVersion
        self.environment = environment
        self.applicationName = applicationName
        self.customContext = customContext
        self.policyStatus = policyStatus
        self.workspacePolicyVersion = workspacePolicyVersion
        self.crash = crash
    }
}
