import Foundation

package struct CrumbReportSettings: Equatable, Sendable {
    package let environment: String
    package let release: CrumbRelease
    package let invocation: Set<CrumbInvocation>
    package let capture: CrumbCaptureOptions
    package let diagnostics: CrumbDiagnosticsOptions
    package let privacy: CrumbPrivacyOptions
}

package struct CrumbUploadSettings: Equatable, Sendable {
    package let projectKey: String
    package let ingestionURL: URL
}

final class CrumbRuntime: @unchecked Sendable {
    static let shared = CrumbRuntime()

    private let lock = NSLock()
    private var configuration: CrumbConfiguration?

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
        return CrumbReportSettings(
            environment: configuration.environment,
            release: configuration.release,
            invocation: configuration.invocation,
            capture: configuration.capture,
            diagnostics: configuration.diagnostics,
            privacy: configuration.privacy
        )
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
