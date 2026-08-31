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

    public init(
        projectKey: String,
        environment: String,
        release: CrumbRelease,
        invocation: Set<CrumbInvocation> = [.shake, .programmatic],
        capture: CrumbCaptureOptions = .init(),
        diagnostics: CrumbDiagnosticsOptions = .init(),
        privacy: CrumbPrivacyOptions = .init(),
        upload: CrumbUploadOptions = .init()
    ) {
        self.projectKey = projectKey
        self.environment = environment
        self.release = release
        self.invocation = invocation
        self.capture = capture
        self.diagnostics = diagnostics
        self.privacy = privacy
        self.upload = upload
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
