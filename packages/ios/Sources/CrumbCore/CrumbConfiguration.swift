import Foundation

public struct CrumbConfiguration: Equatable, Sendable {
    public let projectKey: String
    public let environment: String
    public let release: CrumbRelease
    public let invocation: Set<CrumbInvocation>
    public let capture: CrumbCaptureOptions
    public let diagnostics: CrumbDiagnosticsOptions
    public let privacy: CrumbPrivacyOptions
    public let upload: CrumbUploadOptions
    public let reporter: CrumbReporterOptions
    public let evidence: Set<CrumbEvidenceCategory>
    public let application: CrumbApplicationMetadata
    public let customContext: CrumbCustomContextOptions
    public let workspacePolicy: CrumbWorkspacePolicyOptions

    public init(
        projectKey: String,
        environment: String,
        release: CrumbRelease,
        invocation: Set<CrumbInvocation> = [.shake, .programmatic],
        capture: CrumbCaptureOptions = .init(),
        diagnostics: CrumbDiagnosticsOptions = .init(),
        privacy: CrumbPrivacyOptions = .init(),
        upload: CrumbUploadOptions = .init(),
        reporter: CrumbReporterOptions = .init(),
        evidence: Set<CrumbEvidenceCategory> = Set(CrumbEvidenceCategory.allCases),
        application: CrumbApplicationMetadata = .init(),
        customContext: CrumbCustomContextOptions = .init(),
        workspacePolicy: CrumbWorkspacePolicyOptions = .init()
    ) {
        self.projectKey = projectKey
        self.environment = environment
        self.release = release
        self.invocation = invocation
        self.capture = capture
        self.diagnostics = diagnostics
        self.privacy = privacy
        self.upload = upload
        self.reporter = reporter
        self.evidence = evidence
        self.application = application
        self.customContext = customContext
        self.workspacePolicy = workspacePolicy
    }
}

public struct CrumbUploadOptions: Equatable, Sendable {
    /// Base URL for the Crumb ingestion service. A nil URL keeps upload disabled.
    public let ingestionURL: URL?

    public init(ingestionURL: URL? = nil) {
        self.ingestionURL = ingestionURL
    }
}

public struct CrumbRelease: Equatable, Sendable {
    public let appVersion: String
    public let nativeBuild: String
    public let bundleVersion: String?

    public init(
        appVersion: String,
        nativeBuild: String,
        bundleVersion: String? = nil
    ) {
        self.appVersion = appVersion
        self.nativeBuild = nativeBuild
        self.bundleVersion = bundleVersion
    }
}

public enum CrumbInvocation: String, Hashable, Sendable {
    case shake
    case programmatic
}

public struct CrumbCaptureOptions: Equatable, Sendable {
    public let screenshot: Bool
    public let maximumScreenshotDimension: Int
    public let maximumScreenshotBytes: Int

    public init(
        screenshot: Bool = true,
        maximumScreenshotDimension: Int = 2_048,
        maximumScreenshotBytes: Int = 5_242_880
    ) {
        self.screenshot = screenshot
        self.maximumScreenshotDimension = maximumScreenshotDimension
        self.maximumScreenshotBytes = maximumScreenshotBytes
    }
}

public struct CrumbDiagnosticsOptions: Equatable, Sendable {
    /// Optional public Crumb `/health` URL. A nil URL disables API probing.
    public let healthCheckURL: URL?
    public let timeout: TimeInterval
    public let logs: CrumbLogOptions

    public init(
        healthCheckURL: URL? = nil,
        timeout: TimeInterval = 2,
        logs: CrumbLogOptions = .init()
    ) {
        self.healthCheckURL = healthCheckURL
        self.timeout = timeout
        self.logs = logs
    }
}

public struct CrumbPrivacyOptions: Equatable, Sendable {
    public let maskAllTextInputs: Bool
    public let maskScreenshotsBeforeUpload: Bool

    public init(
        maskAllTextInputs: Bool = true,
        maskScreenshotsBeforeUpload: Bool = true
    ) {
        self.maskAllTextInputs = maskAllTextInputs
        self.maskScreenshotsBeforeUpload = maskScreenshotsBeforeUpload
    }
}

/// Controls the reporter's appearance without allowing host applications to
/// replace Crumb's layout, copy, or branding.
public enum CrumbTheme: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark
}

/// The small set of fields rendered by the built-in reporter.
public enum CrumbReporterField: String, CaseIterable, Hashable, Codable, Sendable {
    case category
    case description
}

/// Optional report-time evidence that can be disabled by the host or made
/// stricter by a workspace policy. Release and runtime identity remain part of
/// the required report envelope.
public enum CrumbEvidenceCategory: String, CaseIterable, Hashable, Codable, Sendable {
    case screenshot
    case performance
    case network
    case logs
    case threadStacks = "thread_stacks"
    case healthCheck = "health_check"
    case customContext = "custom_context"
}

public struct CrumbReporterOptions: Equatable, Sendable {
    public let theme: CrumbTheme
    public let visibleFields: Set<CrumbReporterField>

    public init(
        theme: CrumbTheme = .system,
        visibleFields: Set<CrumbReporterField> = [.category, .description]
    ) {
        self.theme = theme
        self.visibleFields = visibleFields
    }
}

/// Application identity is separate from release identity so an integrator
/// can provide a stable public name while keeping version/build fields in
/// `CrumbRelease`.
public struct CrumbApplicationMetadata: Equatable, Sendable {
    public let name: String?

    public init(name: String? = nil) {
        self.name = name
    }
}

/// Custom context is deliberately a string-only, explicitly allowlisted map.
/// Values are bounded and sanitized again by the effective-policy evaluator
/// before a report envelope is built.
public struct CrumbCustomContextOptions: Equatable, Sendable {
    public let values: [String: String]
    public let allowedKeys: Set<String>

    public init(
        values: [String: String] = [:],
        allowedKeys: Set<String> = []
    ) {
        self.values = values
        self.allowedKeys = allowedKeys
    }
}

/// Enables the optional workspace policy fetch. Omitting the URL preserves
/// the current local-only behavior; when configured, optional evidence stays
/// disabled until a valid policy is fetched or loaded from a still-valid cache.
public struct CrumbWorkspacePolicyOptions: Equatable, Sendable {
    public let url: URL?
    public let timeout: TimeInterval

    public init(
        url: URL? = nil,
        timeout: TimeInterval = 2
    ) {
        self.url = url
        self.timeout = timeout
    }
}
