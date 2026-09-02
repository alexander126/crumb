import Foundation

public enum Crumb {
    public static func start(_ configuration: CrumbConfiguration) throws {
        try CrumbRuntime.shared.start(configuration)
    }

    package static func reportSettings() throws -> CrumbReportSettings {
        try CrumbRuntime.shared.reportSettings()
    }

    package static func uploadSettings() throws -> CrumbUploadSettings? {
        try CrumbRuntime.shared.uploadSettings()
    }

    package static func workspacePolicyFetchSettings() throws -> CrumbPolicyFetchSettings? {
        try CrumbRuntime.shared.workspacePolicyFetchSettings()
    }

    package static func workspacePolicyCacheKey() throws -> String {
        try CrumbRuntime.shared.workspacePolicyCacheKey()
    }

    package static func beginWorkspacePolicyFetch() {
        CrumbRuntime.shared.beginWorkspacePolicyFetch()
    }

    @discardableResult
    package static func applyWorkspacePolicy(
        _ policy: CrumbWorkspacePolicy,
        source: CrumbPolicySource
    ) -> Bool {
        CrumbRuntime.shared.applyWorkspacePolicy(policy, source: source)
    }

    package static func markWorkspacePolicyUnavailable() {
        CrumbRuntime.shared.markWorkspacePolicyUnavailable()
    }

    package static func buildReport(
        _ input: CrumbReportBuildInput
    ) throws -> CrumbSerializedReportEnvelope {
        try CrumbReportEnvelopeBuilder.build(settings: reportSettings(), input: input)
    }

    package static func newReportID() -> String {
        CrumbReportEnvelopeBuilder.makeReportID()
    }

    package static func resetForTesting() {
        CrumbRuntime.shared.resetForTesting()
    }
}

public enum CrumbStartError: Error, Equatable {
    case emptyProjectKey
    case invalidProjectKey
    case emptyEnvironment
    case invalidEnvironment
    case invalidRelease
    case invalidScreenshotDimension
    case invalidScreenshotByteLimit
    case invalidDiagnosticsTimeout
    case invalidHealthCheckURL
    case invalidLogLookback
    case invalidLogLimits
    case invalidIngestionURL
    case invalidReporterFields
    case invalidEvidence
    case invalidApplicationMetadata
    case invalidCustomContext
    case invalidWorkspacePolicyTimeout
    case invalidWorkspacePolicyURL
    case alreadyStartedWithDifferentConfiguration
}
