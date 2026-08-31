import Foundation

package struct CrumbReportRuntime: Equatable, Sendable {
    package let osVersion: String
    package let deviceFamily: String
    package let locale: String
    package let timezone: String

    package init(osVersion: String, deviceFamily: String, locale: String, timezone: String) {
        self.osVersion = osVersion
        self.deviceFamily = deviceFamily
        self.locale = locale
        self.timezone = timezone
    }
}

package enum CrumbScreenshotCaptureState: String, Equatable, Sendable {
    case enabled
    case disabledByConfiguration = "disabled_by_configuration"
    case unavailable
}

package enum CrumbScreenshotMaskingState: String, Equatable, Sendable {
    case applied
    case notApplicable = "not_applicable"
    case failed
}

package struct CrumbArtifactManifest: Equatable, Sendable {
    package let id: String
    package let kind: String
    package let mimeType: String
    package let byteSize: Int
    package let sha256: String
    package let redactionState: String
    package let uploadID: String

    package init(
        id: String,
        kind: String,
        mimeType: String,
        byteSize: Int,
        sha256: String,
        redactionState: String,
        uploadID: String
    ) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.redactionState = redactionState
        self.uploadID = uploadID
    }
}

package struct CrumbReportBuildInput: Equatable, Sendable {
    package let reportID: String
    package let trigger: CrumbInvocation
    package let triggeredAt: Date
    package let submittedAt: Date
    package let runtime: CrumbReportRuntime
    package let category: String
    package let description: String
    package let diagnostics: CrumbDiagnosticsSnapshot
    package let screenshotCapture: CrumbScreenshotCaptureState
    package let screenshotMasking: CrumbScreenshotMaskingState
    package let artifacts: [CrumbArtifactManifest]

    package init(
        reportID: String,
        trigger: CrumbInvocation,
        triggeredAt: Date,
        submittedAt: Date,
        runtime: CrumbReportRuntime,
        category: String,
        description: String,
        diagnostics: CrumbDiagnosticsSnapshot,
        screenshotCapture: CrumbScreenshotCaptureState,
        screenshotMasking: CrumbScreenshotMaskingState,
        artifacts: [CrumbArtifactManifest] = []
    ) {
        self.reportID = reportID
        self.trigger = trigger
        self.triggeredAt = triggeredAt
        self.submittedAt = submittedAt
        self.runtime = runtime
        self.category = category
        self.description = description
        self.diagnostics = diagnostics
        self.screenshotCapture = screenshotCapture
        self.screenshotMasking = screenshotMasking
        self.artifacts = artifacts
    }
}

package struct CrumbSerializedReportEnvelope: Equatable, Sendable {
    package let reportID: String
    package let submittedAt: Date
    package let data: Data

    package var json: String { String(decoding: data, as: UTF8.self) }
}

package enum CrumbReportEnvelopeError: Error, Equatable {
    case invalidConfiguration
    case invalidReportID
    case invalidTimestampOrder
    case invalidRuntime
    case invalidCategory
    case invalidDescription
    case tooManyArtifacts
    case invalidArtifact
}

package enum CrumbReportEnvelopeBuilder {
    package static func makeReportID(uuid: UUID = UUID()) -> String {
        "rpt_" + uuid.uuidString.replacingOccurrences(of: "-", with: "")
    }

    package static func build(
        settings: CrumbReportSettings,
        input: CrumbReportBuildInput
    ) throws -> CrumbSerializedReportEnvelope {
        try validate(settings: settings, input: input)
        let diagnostics = input.diagnostics
        let category = input.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let memory: MemoryDTO? = if diagnostics.residentMemoryBytes != nil
            || diagnostics.physicalFootprintBytes != nil {
            MemoryDTO(
                residentBytes: diagnostics.residentMemoryBytes,
                physicalFootprintBytes: diagnostics.physicalFootprintBytes
            )
        } else {
            nil
        }
        let health = diagnostics.network.healthCheck.map {
            HealthDTO(
                host: $0.host,
                succeeded: $0.succeeded,
                statusCode: $0.statusCode,
                latencyMS: $0.latencyMilliseconds,
                failure: $0.failure
            )
        }
        let logCapture = switch diagnostics.logs.status {
        case .disabled: "disabled_by_configuration"
        case .unavailable: "unavailable"
        case .captured, .empty: "enabled"
        }

        let envelope = EnvelopeDTO(
            schemaVersion: "1.0",
            reportID: input.reportID,
            trigger: input.trigger.rawValue,
            triggeredAt: input.triggeredAt,
            submittedAt: input.submittedAt,
            release: ReleaseDTO(
                platform: "ios",
                appVersion: settings.release.appVersion,
                nativeBuild: settings.release.nativeBuild,
                jsBundleVersion: settings.release.bundleVersion,
                environment: settings.environment
            ),
            sdk: SDKDTO(name: "crumb-ios", version: CrumbSDKVersion.current, integration: "native"),
            runtime: RuntimeDTO(
                os: "ios",
                osVersion: input.runtime.osVersion,
                deviceFamily: input.runtime.deviceFamily,
                locale: input.runtime.locale,
                timezone: input.runtime.timezone
            ),
            userInput: UserInputDTO(
                category: category.lowercased(),
                description: description
            ),
            diagnostics: DiagnosticsDTO(
                capturedAt: diagnostics.capturedAt,
                location: diagnostics.location,
                process: ProcessDTO(name: diagnostics.processName, id: Int(diagnostics.processID)),
                cpuUsagePercent: finite(diagnostics.cpuUsagePercent),
                memory: memory,
                thermalState: diagnostics.thermalState,
                threads: ThreadsDTO(
                    count: diagnostics.threadCount,
                    busiest: diagnostics.busiestThreads.map {
                        ThreadDTO(
                            id: String($0.id),
                            name: $0.name,
                            state: $0.state,
                            cpuUsagePercent: finite($0.cpuUsagePercent)
                        )
                    }
                ),
                gpu: GPUDTO(status: "unavailable_on_demand"),
                network: NetworkDTO(
                    status: diagnostics.network.status,
                    transport: diagnostics.network.transport,
                    cellularGeneration: normalizeGeneration(diagnostics.network.cellularGeneration),
                    isExpensive: diagnostics.network.isExpensive,
                    isConstrained: diagnostics.network.isConstrained,
                    healthCheck: health
                ),
                logs: LogsDTO(
                    status: diagnostics.logs.status.rawValue,
                    sources: diagnostics.logs.sources,
                    entries: diagnostics.logs.entries.map {
                        LogEntryDTO(
                            timestamp: $0.timestamp,
                            level: $0.level.rawValue,
                            source: $0.source,
                            category: $0.category,
                            message: $0.message
                        )
                    },
                    truncated: diagnostics.logs.truncated,
                    droppedEntryCount: diagnostics.logs.droppedEntryCount,
                    failures: diagnostics.logs.failures
                ),
                stackTraces: StackTracesDTO(
                    status: diagnostics.stackTraces.status.rawValue,
                    scope: diagnostics.stackTraces.scope,
                    threads: diagnostics.stackTraces.threads.map {
                        ThreadStackDTO(
                            id: String($0.id),
                            name: $0.name,
                            state: $0.state,
                            frames: $0.frames
                        )
                    },
                    truncated: diagnostics.stackTraces.truncated,
                    unavailableReason: diagnostics.stackTraces.unavailableReason
                )
            ),
            privacy: PrivacyDTO(
                screenshotCapture: input.screenshotCapture.rawValue,
                screenshotMasking: input.screenshotMasking.rawValue,
                diagnosticsCapture: "on_demand",
                logCapture: logCapture
            ),
            artifacts: input.artifacts.map {
                ArtifactDTO(
                    id: $0.id,
                    kind: $0.kind,
                    mimeType: $0.mimeType,
                    byteSize: $0.byteSize,
                    sha256: $0.sha256,
                    redactionState: $0.redactionState,
                    uploadID: $0.uploadID
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return CrumbSerializedReportEnvelope(
            reportID: input.reportID,
            submittedAt: input.submittedAt,
            data: try encoder.encode(envelope)
        )
    }

    private static func validate(
        settings: CrumbReportSettings,
        input: CrumbReportBuildInput
    ) throws {
        guard hasLength(settings.environment, maximum: 64),
              hasLength(settings.release.appVersion, maximum: 64),
              hasLength(settings.release.nativeBuild, maximum: 64),
              settings.release.bundleVersion.map({ hasLength($0, maximum: 128) }) ?? true else {
            throw CrumbReportEnvelopeError.invalidConfiguration
        }
        guard input.reportID.range(
            of: #"^rpt_[A-Za-z0-9_-]{16,80}$"#,
            options: .regularExpression
        ) != nil else {
            throw CrumbReportEnvelopeError.invalidReportID
        }
        guard input.triggeredAt.timeIntervalSinceReferenceDate.isFinite,
              input.submittedAt.timeIntervalSinceReferenceDate.isFinite,
              input.triggeredAt <= input.submittedAt else {
            throw CrumbReportEnvelopeError.invalidTimestampOrder
        }
        guard hasLength(input.runtime.osVersion, maximum: 64),
              hasLength(input.runtime.deviceFamily, maximum: 128),
              hasLength(input.runtime.locale, maximum: 64),
              hasLength(input.runtime.timezone, maximum: 128) else {
            throw CrumbReportEnvelopeError.invalidRuntime
        }
        let category = input.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty, category.unicodeScalars.count <= 64 else {
            throw CrumbReportEnvelopeError.invalidCategory
        }
        let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, description.unicodeScalars.count <= 4_000 else {
            throw CrumbReportEnvelopeError.invalidDescription
        }
        guard input.artifacts.count <= 10 else {
            throw CrumbReportEnvelopeError.tooManyArtifacts
        }
        let artifactIDPattern = try! NSRegularExpression(pattern: "^art_[A-Za-z0-9_-]{12,80}$")
        let uploadIDPattern = try! NSRegularExpression(pattern: "^upl_[A-Za-z0-9_-]{12,80}$")
        let digestPattern = try! NSRegularExpression(pattern: "^[a-f0-9]{64}$")
        let kinds = Set(["screenshot", "annotated_screenshot", "other"])
        let redactionStates = Set(["sanitized", "masked", "not_applicable"])
        for artifact in input.artifacts {
            guard matches(artifact.id, expression: artifactIDPattern),
                  kinds.contains(artifact.kind),
                  hasLength(artifact.mimeType, maximum: 128),
                  artifact.byteSize >= 0,
                  artifact.byteSize <= 26_214_400,
                  matches(artifact.sha256, expression: digestPattern),
                  redactionStates.contains(artifact.redactionState),
                  matches(artifact.uploadID, expression: uploadIDPattern) else {
                throw CrumbReportEnvelopeError.invalidArtifact
            }
        }
    }

    private static func hasLength(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.unicodeScalars.count <= maximum
    }

    private static func matches(_ value: String, expression: NSRegularExpression) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private static func finite(_ value: Double?) -> Double? {
        value?.isFinite == true ? value : nil
    }

    private static func normalizeGeneration(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "2g": "2g"
        case "3g": "3g"
        case "4g/lte", "4g_lte": "4g_lte"
        case "5g": "5g"
        case .some: "unknown"
        case nil: nil
        }
    }
}

private struct EnvelopeDTO: Encodable {
    let schemaVersion: String
    let reportID: String
    let trigger: String
    let triggeredAt: Date
    let submittedAt: Date
    let release: ReleaseDTO
    let sdk: SDKDTO
    let runtime: RuntimeDTO
    let userInput: UserInputDTO
    let diagnostics: DiagnosticsDTO
    let privacy: PrivacyDTO
    let artifacts: [ArtifactDTO]
}

private struct ReleaseDTO: Encodable {
    let platform: String
    let appVersion: String
    let nativeBuild: String
    let jsBundleVersion: String?
    let environment: String
}

private struct SDKDTO: Encodable {
    let name: String
    let version: String
    let integration: String
}

private struct RuntimeDTO: Encodable {
    let os: String
    let osVersion: String
    let deviceFamily: String
    let locale: String
    let timezone: String
}

private struct UserInputDTO: Encodable {
    let category: String
    let description: String
}

private struct DiagnosticsDTO: Encodable {
    let capturedAt: Date
    let location: String
    let process: ProcessDTO
    let cpuUsagePercent: Double?
    let memory: MemoryDTO?
    let thermalState: String
    let threads: ThreadsDTO
    let gpu: GPUDTO
    let network: NetworkDTO
    let logs: LogsDTO
    let stackTraces: StackTracesDTO
}

private struct ProcessDTO: Encodable { let name: String; let id: Int }

private struct MemoryDTO: Encodable {
    let residentBytes: UInt64?
    let physicalFootprintBytes: UInt64?
}

private struct ThreadsDTO: Encodable {
    let count: Int
    let busiest: [ThreadDTO]
}

private struct ThreadDTO: Encodable {
    let id: String
    let name: String
    let state: String
    let cpuUsagePercent: Double?
}

private struct GPUDTO: Encodable { let status: String }

private struct NetworkDTO: Encodable {
    let status: String
    let transport: String
    let cellularGeneration: String?
    let isExpensive: Bool
    let isConstrained: Bool
    let healthCheck: HealthDTO?
}

private struct HealthDTO: Encodable {
    let host: String
    let succeeded: Bool
    let statusCode: Int?
    let latencyMS: Int
    let failure: String?

    private enum CodingKeys: String, CodingKey {
        case host, succeeded, failure
        case statusCode = "status_code"
        case latencyMS = "latency_ms"
    }
}

private struct LogsDTO: Encodable {
    let status: String
    let sources: [String]
    let entries: [LogEntryDTO]
    let truncated: Bool
    let droppedEntryCount: Int
    let failures: [String]
}

private struct LogEntryDTO: Encodable {
    let timestamp: Date
    let level: String
    let source: String
    let category: String
    let message: String
}

private struct StackTracesDTO: Encodable {
    let status: String
    let scope: String
    let threads: [ThreadStackDTO]
    let truncated: Bool
    let unavailableReason: String?
}

private struct ThreadStackDTO: Encodable {
    let id: String
    let name: String
    let state: String
    let frames: [String]
}

private struct PrivacyDTO: Encodable {
    let screenshotCapture: String
    let screenshotMasking: String
    let diagnosticsCapture: String
    let logCapture: String
}

private struct ArtifactDTO: Encodable {
    let id: String
    let kind: String
    let mimeType: String
    let byteSize: Int
    let sha256: String
    let redactionState: String
    let uploadID: String
}
