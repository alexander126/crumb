import Foundation

package struct CrumbJavaScriptCrashRelease: Codable, Equatable, Sendable {
    package let appVersion: String?
    package let nativeBuild: String?
    package let bundleVersion: String?
}

package struct CrumbJavaScriptBreadcrumb: Codable, Equatable, Sendable {
    package let timestamp: Date
    package let source: String
    package let category: String
    package let message: String
}

package struct CrumbJavaScriptCrash: Equatable, Sendable {
    package let recordID: String
    package let fingerprint: String
    package let source: String
    package let kind: String
    package let type: String
    package let message: String
    package let stack: String?
    package let occurredAt: Date
    package let release: CrumbJavaScriptCrashRelease
    package let breadcrumbs: [CrumbJavaScriptBreadcrumb]
    package let context: [String: String]
    package let isFatal: Bool
    package let nativeTerminationWrapperObserved: Bool
}

package struct CrumbJavaScriptCrashStoreLimits: Equatable, Sendable {
    package let maximumRecords: Int
    package let maximumTotalBytes: Int
    package let maximumRecordBytes: Int
    package let maximumBreadcrumbs: Int
    package let maximumBreadcrumbBytes: Int

    package init(
        maximumRecords: Int = 50,
        maximumTotalBytes: Int = 2_097_152,
        maximumRecordBytes: Int = 32_768,
        maximumBreadcrumbs: Int = 32,
        maximumBreadcrumbBytes: Int = 16_384
    ) {
        self.maximumRecords = maximumRecords
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumRecordBytes = maximumRecordBytes
        self.maximumBreadcrumbs = maximumBreadcrumbs
        self.maximumBreadcrumbBytes = maximumBreadcrumbBytes
    }
}

/// A tiny synchronous store used by the React Native adapter's JavaScript
/// exception handoff. It deliberately has no uncaught native exception hook.
package final class CrumbJavaScriptCrashStore: @unchecked Sendable {
    package static let shared = CrumbJavaScriptCrashStore(rootURL: defaultRootURL())

    private let rootURL: URL
    private let limits: CrumbJavaScriptCrashStoreLimits
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    package init(
        rootURL: URL,
        limits: CrumbJavaScriptCrashStoreLimits = .init(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.limits = limits
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    package func record(_ recordJSON: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard validLimits(),
              let data = recordJSON.data(using: .utf8),
              data.count <= limits.maximumRecordBytes,
              let raw = try? decoder.decode(RawRecord.self, from: data),
              let record = normalize(raw) else {
            return false
        }

        do {
            try prepareRoot()
            let existing = try readAllLocked()
            if let match = existing.first(where: { $0.record.fingerprint == record.fingerprint }) {
                let merged = merge(match.record, record)
                let mergedData = try encoded(merged)
                let total = existing.reduce(0) { total, item in
                    total + (item.url == match.url ? mergedData.count : (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                guard mergedData.count <= limits.maximumRecordBytes,
                      total <= limits.maximumTotalBytes else {
                    return false
                }
                try write(mergedData, to: match.url)
                return true
            }

            let encoded = try encoded(record)
            let total = existing.reduce(0) { total, item in
                total + ((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            guard existing.count < limits.maximumRecords,
                  total + encoded.count <= limits.maximumTotalBytes else {
                return false
            }
            try write(encoded, to: url(for: record.recordID))
            return true
        } catch {
            return false
        }
    }

    package func records() -> [CrumbJavaScriptCrash] {
        lock.lock()
        defer { lock.unlock() }
        guard validLimits(), (try? prepareRoot()) != nil,
              let entries = try? readAllLocked() else {
            return []
        }

        var byFingerprint: [String: (url: URL, record: CrumbJavaScriptCrash)] = [:]
        for entry in entries {
            if let prior = byFingerprint[entry.record.fingerprint] {
                let merged = merge(prior.record, entry.record)
                byFingerprint[entry.record.fingerprint] = (prior.url, merged)
                if let data = try? encoded(merged) {
                    try? write(data, to: prior.url)
                    try? fileManager.removeItem(at: entry.url)
                }
            } else {
                byFingerprint[entry.record.fingerprint] = entry
            }
        }
        return byFingerprint.values
            .map(\.record)
            .sorted { $0.occurredAt < $1.occurredAt }
    }

    @discardableResult
    package func remove(recordID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard validRecordID(recordID) else { return false }
        do {
            try prepareRoot()
            let target = url(for: recordID)
            guard fileManager.fileExists(atPath: target.path) else { return false }
            try fileManager.removeItem(at: target)
            return true
        } catch {
            return false
        }
    }

    private func normalize(_ raw: RawRecord) -> CrumbJavaScriptCrash? {
        guard raw.schemaVersion == "1.0",
              validRecordID(raw.recordID),
              raw.fingerprint.range(of: "^[A-Fa-f0-9]{16}$", options: .regularExpression) != nil,
              ["javascript", "native_termination_wrapper"].contains(raw.source),
              ["exception", "unhandled_rejection", "native_termination_wrapper"].contains(raw.kind),
              let occurredAt = parseDate(raw.occurredAt) else {
            return nil
        }

        let type = bounded(CrumbLogSanitizer.sanitize(raw.type).trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: 128)
        let message = bounded(CrumbLogSanitizer.sanitize(raw.message).trimmingCharacters(in: .whitespacesAndNewlines), maximumBytes: 4_000)
        guard !type.isEmpty, !message.isEmpty else { return nil }

        let stack = raw.stack.map {
            bounded(
                CrumbLogSanitizer.sanitize($0.replacingOccurrences(of: "\n", with: "\u{e000}"))
                    .replacingOccurrences(of: "\u{e000}", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                maximumBytes: 16_384
            )
        }.flatMap { $0.isEmpty ? nil : $0 }

        let breadcrumbs = boundedBreadcrumbs(raw.breadcrumbs)
        let context = CrumbCustomContextSanitizer.sanitize(
            CrumbCustomContextOptions(
                values: raw.context,
                allowedKeys: Set(raw.context.keys)
            )
        )
        return CrumbJavaScriptCrash(
            recordID: raw.recordID,
            fingerprint: raw.fingerprint.lowercased(),
            source: raw.source,
            kind: raw.kind,
            type: type,
            message: message,
            stack: stack,
            occurredAt: occurredAt,
            release: CrumbJavaScriptCrashRelease(
                appVersion: raw.release?.appVersion.map { bounded($0, maximumBytes: 64) },
                nativeBuild: raw.release?.nativeBuild.map { bounded($0, maximumBytes: 64) },
                bundleVersion: raw.release?.bundleVersion.map { bounded($0, maximumBytes: 128) }
            ),
            breadcrumbs: breadcrumbs,
            context: context,
            isFatal: raw.isFatal || raw.source == "native_termination_wrapper",
            nativeTerminationWrapperObserved: raw.nativeTerminationWrapperObserved
                || raw.source == "native_termination_wrapper"
        )
    }

    private func boundedBreadcrumbs(_ values: [RawBreadcrumb]) -> [CrumbJavaScriptBreadcrumb] {
        var result: [CrumbJavaScriptBreadcrumb] = []
        var bytes = 0
        for raw in values.suffix(limits.maximumBreadcrumbs) {
            guard let date = parseDate(raw.timestamp) else { continue }
            let breadcrumb = CrumbJavaScriptBreadcrumb(
                timestamp: date,
                source: bounded(CrumbLogSanitizer.sanitize(raw.source), maximumBytes: 64),
                category: bounded(CrumbLogSanitizer.sanitize(raw.category), maximumBytes: 256),
                message: bounded(CrumbLogSanitizer.sanitize(raw.message), maximumBytes: 2_048)
            )
            guard !breadcrumb.source.isEmpty, !breadcrumb.category.isEmpty,
                  !breadcrumb.message.isEmpty,
                  let encoded = try? encoder.encode(breadcrumb),
                  bytes + encoded.count <= limits.maximumBreadcrumbBytes else {
                continue
            }
            result.append(breadcrumb)
            bytes += encoded.count
        }
        return result
    }

    private func merge(
        _ existing: CrumbJavaScriptCrash,
        _ incoming: CrumbJavaScriptCrash
    ) -> CrumbJavaScriptCrash {
        let preferred = incoming.source == "javascript" && existing.source != "javascript"
            ? incoming
            : existing
        let fallback = preferred.recordID == incoming.recordID ? existing : incoming
        return CrumbJavaScriptCrash(
            recordID: preferred.recordID,
            fingerprint: preferred.fingerprint,
            source: preferred.source,
            kind: preferred.kind,
            type: preferred.type,
            message: preferred.message,
            stack: preferred.stack ?? fallback.stack,
            occurredAt: min(existing.occurredAt, incoming.occurredAt),
            release: CrumbJavaScriptCrashRelease(
                appVersion: preferred.release.appVersion ?? fallback.release.appVersion,
                nativeBuild: preferred.release.nativeBuild ?? fallback.release.nativeBuild,
                bundleVersion: preferred.release.bundleVersion ?? fallback.release.bundleVersion
            ),
            breadcrumbs: preferred.breadcrumbs.isEmpty ? fallback.breadcrumbs : preferred.breadcrumbs,
            context: preferred.context.isEmpty ? fallback.context : preferred.context,
            isFatal: existing.isFatal || incoming.isFatal,
            nativeTerminationWrapperObserved: existing.nativeTerminationWrapperObserved
                || incoming.nativeTerminationWrapperObserved
        )
    }

    private func readAllLocked() throws -> [(url: URL, record: CrumbJavaScriptCrash)] {
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= limits.maximumRecordBytes else { throw StoreError.corrupt }
                let raw = try decoder.decode(RawRecord.self, from: data)
                guard let record = normalize(raw) else { throw StoreError.corrupt }
                return (url, record)
            } catch {
                try? fileManager.removeItem(at: url)
                return nil
            }
        }
    }

    private func encoded(_ record: CrumbJavaScriptCrash) throws -> Data {
        try encoder.encode(RawRecord(record))
    }

    private func prepareRoot() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let temporaryFiles = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent.hasPrefix(".tmp-") }
        temporaryFiles?.forEach { try? fileManager.removeItem(at: $0) }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func url(for recordID: String) -> URL {
        rootURL.appendingPathComponent("\(recordID).json")
    }

    private func validLimits() -> Bool {
        limits.maximumRecords > 0
            && limits.maximumTotalBytes > 0
            && limits.maximumRecordBytes > 0
            && limits.maximumRecordBytes <= limits.maximumTotalBytes
            && limits.maximumBreadcrumbs >= 0
            && limits.maximumBreadcrumbBytes > 0
    }

    private func validRecordID(_ value: String) -> Bool {
        value.range(of: "^jsc_[A-Za-z0-9_-]{16,80}$", options: .regularExpression) != nil
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= max(0, maximumBytes - 3) else { break }
            result = candidate
        }
        return result + "…"
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("dev.crumb", isDirectory: true)
            .appendingPathComponent("javascript-crashes", isDirectory: true)
    }

    private enum StoreError: Error { case corrupt }

    private struct RawRecord: Codable {
        let schemaVersion: String
        let recordID: String
        let fingerprint: String
        let source: String
        let kind: String
        let type: String
        let message: String
        let stack: String?
        let occurredAt: String
        let release: RawRelease?
        let breadcrumbs: [RawBreadcrumb]
        let context: [String: String]
        let isFatal: Bool
        let nativeTerminationWrapperObserved: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
            recordID = try container.decode(String.self, forKey: .recordID)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            source = try container.decode(String.self, forKey: .source)
            kind = try container.decode(String.self, forKey: .kind)
            type = try container.decode(String.self, forKey: .type)
            message = try container.decode(String.self, forKey: .message)
            stack = try container.decodeIfPresent(String.self, forKey: .stack)
            occurredAt = try container.decode(String.self, forKey: .occurredAt)
            release = try container.decodeIfPresent(RawRelease.self, forKey: .release)
            breadcrumbs = try container.decodeIfPresent([RawBreadcrumb].self, forKey: .breadcrumbs) ?? []
            context = try container.decodeIfPresent([String: String].self, forKey: .context) ?? [:]
            isFatal = try container.decodeIfPresent(Bool.self, forKey: .isFatal) ?? false
            nativeTerminationWrapperObserved = try container.decodeIfPresent(
                Bool.self,
                forKey: .nativeTerminationWrapperObserved
            ) ?? false
        }

        init(_ record: CrumbJavaScriptCrash) {
            schemaVersion = "1.0"
            recordID = record.recordID
            fingerprint = record.fingerprint
            source = record.source
            kind = record.kind
            type = record.type
            message = record.message
            stack = record.stack
            occurredAt = ISO8601DateFormatter().string(from: record.occurredAt)
            release = RawRelease(record.release)
            breadcrumbs = record.breadcrumbs.map(RawBreadcrumb.init)
            context = record.context
            isFatal = record.isFatal
            nativeTerminationWrapperObserved = record.nativeTerminationWrapperObserved
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case recordID = "record_id"
            case fingerprint
            case source
            case kind
            case type
            case message
            case stack
            case occurredAt = "occurred_at"
            case release
            case breadcrumbs
            case context
            case isFatal = "is_fatal"
            case nativeTerminationWrapperObserved = "native_termination_wrapper_observed"
        }
    }

    private struct RawRelease: Codable {
        let appVersion: String?
        let nativeBuild: String?
        let bundleVersion: String?

        init(_ release: CrumbJavaScriptCrashRelease) {
            appVersion = release.appVersion
            nativeBuild = release.nativeBuild
            bundleVersion = release.bundleVersion
        }

        private enum CodingKeys: String, CodingKey {
            case appVersion = "app_version"
            case nativeBuild = "native_build"
            case bundleVersion = "bundle_version"
        }
    }

    private struct RawBreadcrumb: Codable {
        let timestamp: String
        let source: String
        let category: String
        let message: String

        init(_ breadcrumb: CrumbJavaScriptBreadcrumb) {
            timestamp = ISO8601DateFormatter().string(from: breadcrumb.timestamp)
            source = breadcrumb.source
            category = breadcrumb.category
            message = breadcrumb.message
        }
    }
}
