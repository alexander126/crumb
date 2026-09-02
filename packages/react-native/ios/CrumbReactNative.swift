import CrumbCore
import CrumbUI
import Foundation
import NitroModules

final class CrumbReactNative: HybridCrumbReactNativeSpec {
    private let decoder = JSONDecoder()
    private let logBuffer = ReactNativeLogBuffer()

    func start(configurationJson: String) throws {
        let data = Data(configurationJson.utf8)
        let payload = try decoder.decode(ConfigurationPayload.self, from: data)
        let bundle = Bundle.main
        let appVersion = payload.release?.appVersion
            ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        let nativeBuild = payload.release?.nativeBuild
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"
        let logOptions = payload.diagnostics?.logs ?? .init()

        logBuffer.configure(
            lookback: logOptions.lookbackMs.map { TimeInterval(milliseconds: $0) } ?? 60,
            maximumEntries: logOptions.maximumEntries ?? 200,
            maximumBytes: logOptions.maximumBytes ?? 65_536
        )

        try Crumb.start(
            CrumbConfiguration(
                projectKey: payload.projectKey,
                environment: payload.environment,
                release: CrumbRelease(
                    appVersion: appVersion,
                    nativeBuild: nativeBuild,
                    bundleVersion: payload.release?.bundleVersion
                ),
                invocation: Set(
                    (payload.invocation ?? [.shake, .programmatic]).map(\.native)
                ),
                capture: CrumbCaptureOptions(
                    screenshot: payload.capture?.screenshot ?? true,
                    maximumScreenshotDimension:
                        payload.capture?.maximumScreenshotDimension ?? 2_048,
                    maximumScreenshotBytes:
                        payload.capture?.maximumScreenshotBytes ?? 5_242_880
                ),
                diagnostics: CrumbDiagnosticsOptions(
                    healthCheckURL: try payload.diagnostics?.healthCheckURL(),
                    timeout: payload.diagnostics?.timeoutMs
                        .map { TimeInterval(milliseconds: $0) } ?? 2,
                    logs: CrumbLogOptions(
                        enabled: logOptions.enabled ?? true,
                        lookback: logOptions.lookbackMs
                            .map { TimeInterval(milliseconds: $0) } ?? 60,
                        maximumEntries: logOptions.maximumEntries ?? 200,
                        maximumBytes: logOptions.maximumBytes ?? 65_536,
                        provider: logBuffer
                    )
                ),
                privacy: CrumbPrivacyOptions(
                    maskAllTextInputs: payload.privacy?.maskAllTextInputs ?? true,
                    maskScreenshotsBeforeUpload:
                        payload.privacy?.maskScreenshotsBeforeUpload ?? true
                ),
                reporter: CrumbReporterOptions(
                    theme: payload.reporter?.theme?.native ?? .system,
                    visibleFields: Set(
                        (payload.reporter?.visibleFields ?? [.category, .description]).map(\.native)
                    )
                ),
                evidence: Set(
                    (payload.evidence ?? EvidencePayload.allCases).map(\.native)
                ),
                application: CrumbApplicationMetadata(name: payload.application?.name),
                customContext: CrumbCustomContextOptions(
                    values: payload.customContext?.values ?? [:],
                    allowedKeys: Set(payload.customContext?.allowedKeys ?? [])
                ),
                workspacePolicy: CrumbWorkspacePolicyOptions(
                    url: try payload.workspacePolicy?.url(),
                    timeout: payload.workspacePolicy?.timeoutMs
                        .map { TimeInterval(milliseconds: $0) } ?? 2
                ),
                upload: CrumbUploadOptions(
                    ingestionURL: try payload.upload?.ingestionURL()
                )
            )
        )
    }

    func installReporter() throws -> Promise<Bool> {
        Promise.async { @MainActor in
            Crumb.installReporter()
        }
    }

    func show() throws -> Promise<Bool> {
        Promise.async { @MainActor in
            Crumb.show()
        }
    }

    func addLog(entryJson: String) throws {
        let data = Data(entryJson.utf8)
        let entry = try decoder.decode(LogEntryPayload.self, from: data)
        logBuffer.append(entry.native)
    }

    func clearLogs() throws {
        logBuffer.clear()
    }
}

private struct ConfigurationPayload: Decodable {
    let projectKey: String
    let environment: String
    let release: ReleasePayload?
    let invocation: [InvocationPayload]?
    let capture: CapturePayload?
    let diagnostics: DiagnosticsPayload?
    let privacy: PrivacyPayload?
    let reporter: ReporterPayload?
    let evidence: [EvidencePayload]?
    let application: ApplicationPayload?
    let customContext: CustomContextPayload?
    let workspacePolicy: WorkspacePolicyPayload?
    let upload: UploadPayload?
}

private struct ReleasePayload: Decodable {
    let appVersion: String?
    let nativeBuild: String?
    let bundleVersion: String?
}

private enum InvocationPayload: String, Decodable {
    case shake
    case programmatic

    var native: CrumbInvocation {
        switch self {
        case .shake: .shake
        case .programmatic: .programmatic
        }
    }
}

private struct CapturePayload: Decodable {
    let screenshot: Bool?
    let maximumScreenshotDimension: Int?
    let maximumScreenshotBytes: Int?
}

private struct DiagnosticsPayload: Decodable {
    let healthCheckUrl: String?
    let timeoutMs: Int?
    let logs: LogOptionsPayload?

    func healthCheckURL() throws -> URL? {
        guard let healthCheckUrl else { return nil }
        guard let url = URL(string: healthCheckUrl) else {
            throw BridgeConfigurationError.invalidURL("healthCheckUrl")
        }
        return url
    }
}

private struct LogOptionsPayload: Decodable {
    let enabled: Bool?
    let lookbackMs: Int?
    let maximumEntries: Int?
    let maximumBytes: Int?

    init(
        enabled: Bool? = nil,
        lookbackMs: Int? = nil,
        maximumEntries: Int? = nil,
        maximumBytes: Int? = nil
    ) {
        self.enabled = enabled
        self.lookbackMs = lookbackMs
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }
}

private struct PrivacyPayload: Decodable {
    let maskAllTextInputs: Bool?
    let maskScreenshotsBeforeUpload: Bool?
}

private struct ReporterPayload: Decodable {
    let theme: ThemePayload?
    let visibleFields: [ReporterFieldPayload]?
}

private enum ThemePayload: String, Decodable {
    case system
    case light
    case dark

    var native: CrumbTheme {
        switch self {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum ReporterFieldPayload: String, Decodable {
    case category
    case description

    var native: CrumbReporterField {
        switch self {
        case .category: .category
        case .description: .description
        }
    }
}

private enum EvidencePayload: String, CaseIterable, Decodable {
    case screenshot
    case performance
    case network
    case logs
    case threadStacks = "thread_stacks"
    case healthCheck = "health_check"
    case customContext = "custom_context"

    var native: CrumbEvidenceCategory {
        switch self {
        case .screenshot: .screenshot
        case .performance: .performance
        case .network: .network
        case .logs: .logs
        case .threadStacks: .threadStacks
        case .healthCheck: .healthCheck
        case .customContext: .customContext
        }
    }
}

private struct ApplicationPayload: Decodable {
    let name: String?
}

private struct CustomContextPayload: Decodable {
    let values: [String: String]?
    let allowedKeys: [String]?
}

private struct WorkspacePolicyPayload: Decodable {
    let urlString: String?
    let timeoutMs: Int?

    enum CodingKeys: String, CodingKey {
        case urlString = "url"
        case timeoutMs
    }

    func url() throws -> URL? {
        guard let urlString else { return nil }
        guard let url = URL(string: urlString) else {
            throw BridgeConfigurationError.invalidURL("workspacePolicy.url")
        }
        return url
    }
}

private struct UploadPayload: Decodable {
    let ingestionUrl: String?

    func ingestionURL() throws -> URL? {
        guard let ingestionUrl else { return nil }
        guard let url = URL(string: ingestionUrl) else {
            throw BridgeConfigurationError.invalidURL("ingestionUrl")
        }
        return url
    }
}

private enum BridgeConfigurationError: Error {
    case invalidURL(String)
}

private struct LogEntryPayload: Decodable {
    let timestampMs: Int64
    let level: String
    let source: String
    let category: String
    let message: String

    var native: CrumbLogEntry {
        CrumbLogEntry(
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1_000),
            level: level.nativeLogLevel,
            source: source,
            category: category,
            message: message
        )
    }
}

private extension String {
    var nativeLogLevel: CrumbLogLevel {
        switch self {
        case "debug": .debug
        case "notice": .notice
        case "warning": .warning
        case "error": .error
        case "fault": .fault
        default: .info
        }
    }
}

private final class ReactNativeLogBuffer: CrumbLogProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CrumbLogEntry] = []
    private var lookback: TimeInterval = 60
    private var maximumEntries = 200
    private var maximumBytes = 65_536

    func configure(
        lookback: TimeInterval,
        maximumEntries: Int,
        maximumBytes: Int
    ) {
        withLock {
            self.lookback = lookback
            self.maximumEntries = maximumEntries
            self.maximumBytes = maximumBytes
            prune(now: Date())
        }
    }

    func append(_ entry: CrumbLogEntry) {
        withLock {
            entries.append(entry)
            prune(now: Date())
        }
    }

    func clear() {
        withLock {
            entries.removeAll(keepingCapacity: false)
        }
    }

    func recentLogs() throws -> [CrumbLogEntry] {
        withLock {
            prune(now: Date())
            return entries
        }
    }

    private func prune(now: Date) {
        let earliest = now.addingTimeInterval(-lookback)
        entries.removeAll { $0.timestamp < earliest }
        while entries.count > maximumEntries || byteCount(entries) > maximumBytes {
            entries.removeFirst()
        }
    }

    private func byteCount(_ entries: [CrumbLogEntry]) -> Int {
        entries.reduce(into: 0) { total, entry in
            total += entry.source.utf8.count
                + entry.category.utf8.count
                + entry.message.utf8.count
                + 32
        }
    }

    private func withLock<Result>(_ action: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try action()
    }
}

private extension TimeInterval {
    init(milliseconds: Int) {
        self = TimeInterval(milliseconds) / 1_000
    }
}
