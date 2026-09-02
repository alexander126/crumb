import Foundation
import CryptoKit

package struct CrumbReportSettings: Equatable, Sendable {
    package let environment: String
    package let release: CrumbRelease
    package let invocation: Set<CrumbInvocation>
    package let capture: CrumbCaptureOptions
    package let diagnostics: CrumbDiagnosticsOptions
    package let privacy: CrumbPrivacyOptions
    package let reporter: CrumbReporterOptions
    package let evidence: Set<CrumbEvidenceCategory>
    package let application: CrumbApplicationMetadata
    package let customContext: [String: String]
    package let policyStatus: CrumbPolicyStatus
    package let workspacePolicyVersion: Int?
}

package struct CrumbUploadSettings: Equatable, Sendable {
    package let projectKey: String
    package let ingestionURL: URL
}

final class CrumbRuntime: @unchecked Sendable {
    static let shared = CrumbRuntime()

    private let lock = NSLock()
    private var configuration: CrumbConfiguration?
    private var workspacePolicy: CrumbWorkspacePolicy?
    private var highestWorkspacePolicyVersion: Int?
    private var policyStatus: CrumbPolicyStatus = .notFetched

    private init() {}

    func start(_ configuration: CrumbConfiguration) throws {
        try Self.validate(configuration)

        lock.lock()
        defer { lock.unlock() }

        if let existing = self.configuration {
            guard existing == configuration else {
                throw CrumbStartError.alreadyStartedWithDifferentConfiguration
            }
            return
        }
        self.configuration = configuration
    }

    func reportSettings() throws -> CrumbReportSettings {
        lock.lock()
        defer { lock.unlock() }

        guard let configuration else { throw CrumbRuntimeError.notStarted }
        let effective = effectiveSettings(for: configuration)
        return CrumbReportSettings(
            environment: configuration.environment,
            release: configuration.release,
            invocation: configuration.invocation,
            capture: configuration.capture,
            diagnostics: configuration.diagnostics,
            privacy: configuration.privacy,
            reporter: CrumbReporterOptions(
                theme: configuration.reporter.theme,
                visibleFields: effective.reporterFields
            ),
            evidence: effective.evidence,
            application: configuration.application,
            customContext: effective.customContext,
            policyStatus: effective.status,
            workspacePolicyVersion: effective.workspacePolicyVersion
        )
    }

    func workspacePolicyFetchSettings() throws -> CrumbPolicyFetchSettings? {
        lock.lock()
        defer { lock.unlock() }

        guard let configuration else { throw CrumbRuntimeError.notStarted }
        guard let url = configuration.workspacePolicy.url else { return nil }
        return CrumbPolicyFetchSettings(
            projectKey: configuration.projectKey,
            url: url,
            timeout: configuration.workspacePolicy.timeout
        )
    }

    func workspacePolicyCacheKey() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let configuration else { throw CrumbRuntimeError.notStarted }
        let digest = SHA256.hash(data: Data(configuration.projectKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "crumb.workspace-policy.\(digest)"
    }

    func beginWorkspacePolicyFetch() {
        lock.lock()
        defer { lock.unlock() }
        guard configuration?.workspacePolicy.url != nil else { return }
        policyStatus = workspacePolicy?.isValid(at: Date()) == true ? .cached : .fetching
    }

    @discardableResult
    func applyWorkspacePolicy(_ policy: CrumbWorkspacePolicy, source: CrumbPolicySource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard configuration?.workspacePolicy.url != nil,
              policy.isValid(at: Date()) else {
            return false
        }
        if highestWorkspacePolicyVersion.map({ $0 > policy.version }) == true {
            return false
        }
        workspacePolicy = policy
        highestWorkspacePolicyVersion = max(highestWorkspacePolicyVersion ?? 0, policy.version)
        policyStatus = source == .fresh ? .fresh : .cached
        return true
    }

    func markWorkspacePolicyUnavailable() {
        lock.lock()
        defer { lock.unlock() }
        guard configuration?.workspacePolicy.url != nil else { return }
        if workspacePolicy?.isValid(at: Date()) != true {
            workspacePolicy = nil
            policyStatus = .unavailable
        }
    }

    func uploadSettings() throws -> CrumbUploadSettings? {
        lock.lock()
        defer { lock.unlock() }

        guard let configuration else { throw CrumbRuntimeError.notStarted }
        guard let ingestionURL = configuration.upload.ingestionURL else { return nil }
        return CrumbUploadSettings(
            projectKey: configuration.projectKey,
            ingestionURL: ingestionURL
        )
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        configuration = nil
        workspacePolicy = nil
        highestWorkspacePolicyVersion = nil
        policyStatus = .notFetched
    }

    private static func validate(_ configuration: CrumbConfiguration) throws {
        guard !configuration.projectKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CrumbStartError.emptyProjectKey
        }
        guard hasPrintableLength(configuration.projectKey, maximum: 512) else {
            throw CrumbStartError.invalidProjectKey
        }
        guard !configuration.environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CrumbStartError.emptyEnvironment
        }
        guard hasPrintableLength(configuration.environment, maximum: 64) else {
            throw CrumbStartError.invalidEnvironment
        }
        guard
            hasPrintableLength(configuration.release.appVersion, maximum: 64),
            hasPrintableLength(configuration.release.nativeBuild, maximum: 64),
            configuration.release.bundleVersion.map({
                hasPrintableLength($0, maximum: 128)
            }) ?? true
        else {
            throw CrumbStartError.invalidRelease
        }
        guard configuration.reporter.visibleFields.contains(.description) else {
            throw CrumbStartError.invalidReporterFields
        }
        guard Set(CrumbEvidenceCategory.allCases).isSuperset(of: configuration.evidence) else {
            throw CrumbStartError.invalidEvidence
        }
        if let name = configuration.application.name,
           !hasPrintableLength(name, maximum: 256) {
            throw CrumbStartError.invalidApplicationMetadata
        }
        guard
            configuration.customContext.values.count <= CrumbCustomContextSanitizer.maximumKeys,
            configuration.customContext.allowedKeys.count <= CrumbCustomContextSanitizer.maximumKeys,
            configuration.customContext.values.keys.allSatisfy({
                CrumbCustomContextSanitizer.isValidKey($0)
            }),
            configuration.customContext.allowedKeys.allSatisfy({
                CrumbCustomContextSanitizer.isValidKey($0)
            })
        else {
            throw CrumbStartError.invalidCustomContext
        }
        guard configuration.workspacePolicy.timeout >= 0.25,
              configuration.workspacePolicy.timeout <= 5 else {
            throw CrumbStartError.invalidWorkspacePolicyTimeout
        }
        if let url = configuration.workspacePolicy.url,
           !validHTTPURL(url) {
            throw CrumbStartError.invalidWorkspacePolicyURL
        }
        guard (320...4_096).contains(configuration.capture.maximumScreenshotDimension) else {
            throw CrumbStartError.invalidScreenshotDimension
        }
        guard (65_536...26_214_400).contains(configuration.capture.maximumScreenshotBytes) else {
            throw CrumbStartError.invalidScreenshotByteLimit
        }
        guard (0.25...5).contains(configuration.diagnostics.timeout) else {
            throw CrumbStartError.invalidDiagnosticsTimeout
        }
        if let url = configuration.diagnostics.healthCheckURL,
           !validHTTPURL(url) {
            throw CrumbStartError.invalidHealthCheckURL
        }
        guard (1...300).contains(configuration.diagnostics.logs.lookback) else {
            throw CrumbStartError.invalidLogLookback
        }
        guard
            (1...500).contains(configuration.diagnostics.logs.maximumEntries),
            (1_024...262_144).contains(configuration.diagnostics.logs.maximumBytes)
        else {
            throw CrumbStartError.invalidLogLimits
        }
        if let url = configuration.upload.ingestionURL {
            guard validHTTPURL(url) else {
                throw CrumbStartError.invalidIngestionURL
            }
        }
    }

    private func effectiveSettings(
        for configuration: CrumbConfiguration,
        now: Date = Date()
    ) -> CrumbEffectivePolicy {
        let status: CrumbPolicyStatus
        if configuration.workspacePolicy.url == nil {
            status = .notConfigured
        } else if let workspacePolicy,
                  workspacePolicy.isValid(at: now),
                  policyStatus == .fresh || policyStatus == .cached {
            status = policyStatus
        } else if workspacePolicy.map({ $0.expiresAt <= now }) == true {
            status = .expired
        } else {
            status = policyStatus
        }
        return CrumbPolicyEvaluator.effective(
            for: configuration,
            workspacePolicy: workspacePolicy,
            status: status,
            now: now
        )
    }

    private static func validHTTPURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") &&
            url.host != nil &&
            url.user == nil &&
            url.password == nil &&
            url.query == nil &&
            url.fragment == nil
    }

    private static func hasPrintableLength(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && value.unicodeScalars.count <= maximum
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

package enum CrumbRuntimeError: Error, Equatable {
    case notStarted
}
