#if canImport(Darwin)
import Darwin
#endif
import Foundation

package enum CrumbJavaScriptCrashEnvelopeBuilder {
    package static func build(
        settings: CrumbReportSettings,
        record: CrumbJavaScriptCrashRecord,
        runtime: CrumbReportRuntime
    ) throws -> CrumbSerializedReportEnvelope {
        let crash = record.crash
        let description = truncateUTF8(
            "\(crash.errorType): \(crash.message)",
            maximumBytes: 4_000
        )
        let customContext = record.customContext.filter {
            settings.customContext[$0.key] == $0.value
        }
        let envelope = JavaScriptCrashEnvelopeDTO(
            schemaVersion: "1.0",
            reportID: record.reportID,
            trigger: "javascript_crash",
            triggeredAt: crash.occurredAt,
            submittedAt: crash.occurredAt,
            release: ReleaseDTO(
                platform: "react_native",
                appVersion: record.appVersion,
                nativeBuild: record.nativeBuild,
                jsBundleVersion: record.bundleVersion,
                environment: record.environment
            ),
            application: record.applicationName.map { ApplicationDTO(name: $0) },
            sdk: SDKDTO(
                name: "crumb-react-native",
                version: CrumbSDKVersion.current,
                integration: "react_native"
            ),
            runtime: RuntimeDTO(
                os: "ios",
                osVersion: runtime.osVersion,
                deviceFamily: runtime.deviceFamily,
                locale: runtime.locale,
                timezone: runtime.timezone
            ),
            userInput: UserInputDTO(
                category: "javascript_crash",
                description: description
            ),
            javascriptCrash: JavaScriptCrashDTO(
                source: crash.source.rawValue,
                kind: crash.kind.rawValue,
                errorType: crash.errorType,
                message: crash.message,
                rawStack: crash.rawStack,
                deduplicationKey: crash.fingerprint ?? "js_unknown",
                nativeTerminationWrapper: crash.nativeTerminationWrapper,
                breadcrumbs: crash.breadcrumbs.map {
                    BreadcrumbDTO(
                        timestamp: $0.timestamp,
                        category: $0.category,
                        message: $0.message
                    )
                }
            ),
            diagnostics: DiagnosticsDTO(
                capturedAt: crash.occurredAt,
                location: "javascript_crash_recovery",
                process: ProcessDTO(
                    name: ProcessInfo.processInfo.processName,
                    id: processID()
                ),
                thermalState: "unavailable",
                threads: ThreadsDTO(count: 0, busiest: []),
                gpu: GPUDTO(status: "unavailable_on_demand"),
                network: NetworkDTO(
                    status: "unknown",
                    transport: "unknown",
                    cellularGeneration: nil,
                    isExpensive: false,
                    isConstrained: false,
                    healthCheck: nil
                ),
                logs: LogsDTO(
                    status: "unavailable",
                    sources: [],
                    entries: [],
                    truncated: false,
                    droppedEntryCount: 0,
                    failures: ["crash_recovery"]
                ),
                stackTraces: StackTracesDTO(
                    status: "unavailable",
                    scope: "none",
                    threads: [],
                    truncated: false,
                    unavailableReason: "crash_recovery"
                )
            ),
            privacy: PrivacyDTO(
                screenshotCapture: "not_applicable",
                screenshotMasking: "not_applicable",
                diagnosticsCapture: "crash_recovery",
                logCapture: "not_applicable",
                policyStatus: settings.policyStatus.rawValue,
                workspacePolicyVersion: settings.workspacePolicyVersion
            ),
            customContext: customContext.isEmpty ? nil : customContext,
            artifacts: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return CrumbSerializedReportEnvelope(
            reportID: record.reportID,
            submittedAt: crash.occurredAt,
            data: try encoder.encode(envelope)
        )
    }

    private static func processID() -> Int {
        #if canImport(Darwin)
        return Int(getpid())
        #else
        return 1
        #endif
    }

    private static func truncateUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        for character in value {
            let candidate = result + String(character)
            if candidate.utf8.count + 3 > maximumBytes { break }
            result = candidate
        }
        return result + "…"
    }
}

package enum CrumbJavaScriptCrashRecovery {
    package static func recoverPending() async -> Int {
        guard let settings = try? Crumb.reportSettings() else { return 0 }
        return await recoverPending(
            store: .shared,
            queue: .shared,
            settings: settings,
            runtime: CrumbReportRuntime(
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                deviceFamily: "iOS",
                locale: Locale.current.identifier,
                timezone: TimeZone.current.identifier
            )
        )
    }

    package static func recoverPending(
        store: CrumbJavaScriptCrashStore,
        queue: CrumbReportQueue,
        settings: CrumbReportSettings,
        runtime: CrumbReportRuntime
    ) async -> Int {
        let queuedIDs: Set<String>
        do {
            queuedIDs = Set(try await queue.reports().map(\.reportID))
        } catch {
            return 0
        }

        var recovered = 0
        for record in store.records() {
            if queuedIDs.contains(record.reportID) {
                if store.remove(reportID: record.reportID) { recovered += 1 }
                continue
            }

            guard let envelope = try? CrumbJavaScriptCrashEnvelopeBuilder.build(
                settings: settings,
                record: record,
                runtime: runtime
            ) else {
                continue
            }

            do {
                _ = try await queue.enqueue(envelope: envelope, artifacts: [])
                if store.remove(reportID: record.reportID) { recovered += 1 }
            } catch CrumbReportQueueError.queueFull {
                break
            } catch {
                // Keep the pending handoff when storage is unavailable or corrupt.
            }
        }
        return recovered
    }
}

private struct JavaScriptCrashEnvelopeDTO: Encodable {
    let schemaVersion: String
    let reportID: String
    let trigger: String
    let triggeredAt: Date
    let submittedAt: Date
    let release: ReleaseDTO
    let application: ApplicationDTO?
    let sdk: SDKDTO
    let runtime: RuntimeDTO
    let userInput: UserInputDTO
    let javascriptCrash: JavaScriptCrashDTO
    let diagnostics: DiagnosticsDTO
    let privacy: PrivacyDTO
    let customContext: [String: String]?
    let artifacts: [String]
}

private struct ReleaseDTO: Encodable {
    let platform: String
    let appVersion: String
    let nativeBuild: String
    let jsBundleVersion: String?
    let environment: String
}

private struct ApplicationDTO: Encodable { let name: String }

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

private struct JavaScriptCrashDTO: Encodable {
    let source: String
    let kind: String
    let errorType: String
    let message: String
    let rawStack: String?
    let deduplicationKey: String
    let nativeTerminationWrapper: Bool
    let breadcrumbs: [BreadcrumbDTO]
}

private struct BreadcrumbDTO: Encodable {
    let timestamp: Date
    let category: String
    let message: String
}

private struct DiagnosticsDTO: Encodable {
    let capturedAt: Date
    let location: String
    let process: ProcessDTO
    let thermalState: String
    let threads: ThreadsDTO
    let gpu: GPUDTO
    let network: NetworkDTO
    let logs: LogsDTO
    let stackTraces: StackTracesDTO
}

private struct ProcessDTO: Encodable {
    let name: String
    let id: Int
}

private struct ThreadsDTO: Encodable {
    let count: Int
    let busiest: [String]
}

private struct GPUDTO: Encodable { let status: String }

private struct NetworkDTO: Encodable {
    let status: String
    let transport: String
    let cellularGeneration: String?
    let isExpensive: Bool
    let isConstrained: Bool
    let healthCheck: String?
}

private struct LogsDTO: Encodable {
    let status: String
    let sources: [String]
    let entries: [String]
    let truncated: Bool
    let droppedEntryCount: Int
    let failures: [String]
}

private struct StackTracesDTO: Encodable {
    let status: String
    let scope: String
    let threads: [String]
    let truncated: Bool
    let unavailableReason: String?
}

private struct PrivacyDTO: Encodable {
    let screenshotCapture: String
    let screenshotMasking: String
    let diagnosticsCapture: String
    let logCapture: String
    let policyStatus: String
    let workspacePolicyVersion: Int?
}
