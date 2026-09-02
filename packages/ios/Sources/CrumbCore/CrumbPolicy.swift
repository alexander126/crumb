import CryptoKit
import Foundation

/// Version for the public, host-owned configuration contract. It is separate
/// from the report-envelope schema version.
public enum CrumbConfigurationContract {
    public static let version = "1.0"
}

public enum CrumbPolicyStatus: String, Codable, Equatable, Sendable {
    case notConfigured = "not_configured"
    case notFetched = "not_fetched"
    case fetching
    case fresh
    case cached
    case unavailable
    case expired
}

package enum CrumbPolicySource {
    case fresh
    case cached
}

public enum CrumbWorkspacePolicyError: Error, Equatable {
    case invalid
    case unsupportedSchema
    case expired
}

/// The only remote control surface in v1. A policy can remove locally enabled
/// evidence, hide the optional category field, and further narrow the host's
/// custom-context allowlist. It has no fields that can enable collection,
/// change reporter layout, or replace Crumb copy and branding.
public struct CrumbWorkspacePolicy: Equatable, Sendable {
    public static let schemaVersion = "1.0"

    public let version: Int
    public let expiresAt: Date
    public let disabledEvidence: Set<CrumbEvidenceCategory>
    public let hiddenReporterFields: Set<CrumbReporterField>
    public let allowedContextKeys: Set<String>

    public init(
        version: Int,
        expiresAt: Date,
        disabledEvidence: Set<CrumbEvidenceCategory> = [],
        hiddenReporterFields: Set<CrumbReporterField> = [],
        allowedContextKeys: Set<String> = []
    ) {
        self.version = version
        self.expiresAt = expiresAt
        self.disabledEvidence = disabledEvidence
        self.hiddenReporterFields = hiddenReporterFields
        self.allowedContextKeys = allowedContextKeys
    }

    public static func decode(
        _ data: Data,
        now: Date = Date()
    ) throws -> CrumbWorkspacePolicy {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw CrumbWorkspacePolicyError.invalid
        }

        let expectedKeys: Set<String> = [
            "schema_version",
            "version",
            "expires_at",
            "disabled_evidence",
            "hidden_reporter_fields",
            "allowed_context_keys"
        ]
        guard Set(dictionary.keys) == expectedKeys else {
            throw CrumbWorkspacePolicyError.invalid
        }
        guard dictionary["schema_version"] as? String == schemaVersion else {
            throw CrumbWorkspacePolicyError.unsupportedSchema
        }
        guard let version = dictionary["version"] as? Int, (1...Int.max).contains(version),
              let expiresText = dictionary["expires_at"] as? String,
              let expiresAt = parseISO8601(expiresText)
        else {
            throw CrumbWorkspacePolicyError.invalid
        }
        guard expiresAt > now else {
            throw CrumbWorkspacePolicyError.expired
        }

        let disabledEvidence = try parseEnumSet(
            dictionary["disabled_evidence"],
            as: CrumbEvidenceCategory.self,
            maximum: CrumbEvidenceCategory.allCases.count
        )
        let hiddenReporterFields = try parseEnumSet(
            dictionary["hidden_reporter_fields"],
            as: CrumbReporterField.self,
            maximum: CrumbReporterField.allCases.count
        )
        guard !hiddenReporterFields.contains(.description) else {
            // The description is the required text report and may not be
            // removed by a workspace policy.
            throw CrumbWorkspacePolicyError.invalid
        }
        let allowedContextKeys = try parseStringSet(
            dictionary["allowed_context_keys"],
            maximum: 16,
            maximumLength: 64
        )
        return CrumbWorkspacePolicy(
            version: version,
            expiresAt: expiresAt,
            disabledEvidence: disabledEvidence,
            hiddenReporterFields: hiddenReporterFields,
            allowedContextKeys: allowedContextKeys
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func parseEnumSet<Enum: RawRepresentable & Hashable>(
        _ value: Any?,
        as type: Enum.Type,
        maximum: Int
    ) throws -> Set<Enum> where Enum.RawValue == String {
        guard let values = value as? [String],
              values.count <= maximum,
              Set(values).count == values.count,
              values.allSatisfy({ type.init(rawValue: $0) != nil })
        else {
            throw CrumbWorkspacePolicyError.invalid
        }
        return Set(values.compactMap(type.init(rawValue:)))
    }

    private static func parseStringSet(
        _ value: Any?,
        maximum: Int,
        maximumLength: Int
    ) throws -> Set<String> {
        guard let values = value as? [String],
              values.count <= maximum,
              Set(values).count == values.count,
              values.allSatisfy({ CrumbCustomContextSanitizer.isValidKey($0, maximum: maximumLength) })
        else {
            throw CrumbWorkspacePolicyError.invalid
        }
        return Set(values)
    }

    package func isValid(at now: Date) -> Bool {
        version > 0 &&
            expiresAt > now &&
            disabledEvidence.count <= CrumbEvidenceCategory.allCases.count &&
            hiddenReporterFields.count <= CrumbReporterField.allCases.count &&
            !hiddenReporterFields.contains(.description) &&
            allowedContextKeys.count <= CrumbCustomContextSanitizer.maximumKeys &&
            allowedContextKeys.allSatisfy({ CrumbCustomContextSanitizer.isValidKey($0) })
    }
}

public struct CrumbEffectivePolicy: Equatable, Sendable {
    public let evidence: Set<CrumbEvidenceCategory>
    public let reporterFields: Set<CrumbReporterField>
    public let customContext: [String: String]
    public let status: CrumbPolicyStatus
    public let workspacePolicyVersion: Int?

    public var hasValidWorkspacePolicy: Bool {
        status == .fresh || status == .cached
    }
}

public enum CrumbPolicyEvaluator {
    public static func localEvidence(for configuration: CrumbConfiguration) -> Set<CrumbEvidenceCategory> {
        var evidence = configuration.evidence
        if !configuration.capture.screenshot {
            evidence.remove(.screenshot)
        }
        if !configuration.diagnostics.logs.enabled {
            evidence.remove(.logs)
        }
        if configuration.diagnostics.healthCheckURL == nil {
            evidence.remove(.healthCheck)
        }
        return evidence
    }

    public static func effective(
        for configuration: CrumbConfiguration,
        workspacePolicy: CrumbWorkspacePolicy?,
        status: CrumbPolicyStatus,
        now: Date = Date()
    ) -> CrumbEffectivePolicy {
        let localEvidence = localEvidence(for: configuration)
        let localContext = localEvidence.contains(.customContext)
            ? CrumbCustomContextSanitizer.sanitize(configuration.customContext)
            : [:]
        let requiresWorkspacePolicy = configuration.workspacePolicy.url != nil
        let policyIsValid = requiresWorkspacePolicy
            && workspacePolicy?.isValid(at: now) == true
            && (status == .fresh || status == .cached)

        if !requiresWorkspacePolicy {
            return CrumbEffectivePolicy(
                evidence: localEvidence,
                reporterFields: configuration.reporter.visibleFields,
                customContext: localContext,
                status: .notConfigured,
                workspacePolicyVersion: nil
            )
        }

        guard policyIsValid, let workspacePolicy else {
            return CrumbEffectivePolicy(
                evidence: [],
                reporterFields: configuration.reporter.visibleFields.intersection([.description]),
                customContext: [:],
                status: status == .expired ? .expired : status,
                workspacePolicyVersion: nil
            )
        }

        var evidence = localEvidence
        evidence.subtract(workspacePolicy.disabledEvidence)
        var reporterFields = configuration.reporter.visibleFields
        reporterFields.subtract(workspacePolicy.hiddenReporterFields)
        reporterFields.insert(.description)
        let customContext = evidence.contains(.customContext)
            ? CrumbCustomContextSanitizer.sanitize(
                configuration.customContext,
                allowedByPolicy: workspacePolicy.allowedContextKeys
            )
            : [:]
        return CrumbEffectivePolicy(
            evidence: evidence,
            reporterFields: reporterFields,
            customContext: customContext,
            status: status,
            workspacePolicyVersion: workspacePolicy.version
        )
    }

}

public enum CrumbCustomContextSanitizer {
    public static let maximumKeys = 16
    public static let maximumKeyLength = 64
    public static let maximumValueBytes = 512
    public static let maximumTotalBytes = 8_192

    public static func sanitize(
        _ options: CrumbCustomContextOptions,
        allowedByPolicy: Set<String>? = nil
    ) -> [String: String] {
        let policyKeys = allowedByPolicy ?? options.allowedKeys
        let allowedKeys = options.allowedKeys.intersection(policyKeys)
            .filter { isValidKey($0, maximum: maximumKeyLength) }
            .sorted()
        var result: [String: String] = [:]
        var totalBytes = 0

        for key in allowedKeys.prefix(maximumKeys) {
            guard let supplied = options.values[key] else { continue }
            guard !isSensitiveKey(key) else { continue }
            let sanitized = CrumbLogSanitizer.sanitize(supplied)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitized.isEmpty else { continue }
            let value = truncateUTF8(sanitized, maximumBytes: maximumValueBytes)
            let entryBytes = key.utf8.count + value.utf8.count
            guard totalBytes + entryBytes <= maximumTotalBytes else { break }
            result[key] = value
            totalBytes += entryBytes
        }
        return result
    }

    package static func isValidKey(_ value: String, maximum: Int = maximumKeyLength) -> Bool {
        guard value.unicodeScalars.count <= maximum else { return false }
        return value.range(of: #"^[A-Za-z][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return [
            "password", "passwd", "secret", "token", "authorization", "cookie",
            "api_key", "apikey", "access_key", "private_key", "card", "cvv", "cvc",
            "ssn", "email", "phone", "address"
        ].contains { lowered.contains($0) }
    }

    private static func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumBytes - 3 else { break }
            result = candidate
        }
        return result + "…"
    }
}

package struct CrumbPolicyFetchSettings: Sendable {
    package let projectKey: String
    package let url: URL
    package let timeout: TimeInterval

    package init(projectKey: String, url: URL, timeout: TimeInterval) {
        self.projectKey = projectKey
        self.url = url
        self.timeout = timeout
    }
}

package enum CrumbPolicyCache {
    package static let maximumBytes = 65_536

    package static func load(
        data: Data?,
        now: Date = Date()
    ) -> CrumbWorkspacePolicy? {
        guard let data, data.count <= maximumBytes else { return nil }
        return try? CrumbWorkspacePolicy.decode(data, now: now)
    }
}
