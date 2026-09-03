import Foundation

package enum CrumbJavaScriptCrashRecovery {
    package static func recover(settings: CrumbReportSettings) async -> Bool {
        let store = CrumbJavaScriptCrashStore.shared
        let pending = store.records()
        guard !pending.isEmpty else { return false }

        var recovered = false
        for crash in pending {
            let reportID = recoveryReportID(for: crash.recordID)
            if let queued = try? await CrumbReportQueue.shared.reports(),
               queued.contains(where: { $0.reportID == reportID }) {
                recovered = store.remove(recordID: crash.recordID) || recovered
                continue
            }
            let release = CrumbRelease(
                appVersion: crash.release.appVersion ?? settings.release.appVersion,
                nativeBuild: crash.release.nativeBuild ?? settings.release.nativeBuild,
                bundleVersion: crash.release.bundleVersion ?? settings.release.bundleVersion
            )
            let reportCrash = CrumbJavaScriptCrash(
                recordID: crash.recordID,
                fingerprint: crash.fingerprint,
                source: crash.source,
                kind: crash.kind,
                type: crash.type,
                message: crash.message,
                stack: crash.stack,
                occurredAt: crash.occurredAt,
                release: CrumbJavaScriptCrashRelease(
                    appVersion: release.appVersion,
                    nativeBuild: release.nativeBuild,
                    bundleVersion: release.bundleVersion
                ),
                breadcrumbs: crash.breadcrumbs,
                context: settings.evidence.contains(.customContext)
                    ? crash.context.filter { settings.customContext[$0.key] != nil }
                    : [:],
                isFatal: crash.isFatal,
                nativeTerminationWrapperObserved: crash.nativeTerminationWrapperObserved
            )
            let occurredAt = crash.occurredAt
            let description = "JavaScript \(crash.kind): \(crash.message)"
            let input = CrumbReportBuildInput(
                reportID: reportID,
                trigger: .programmatic,
                triggeredAt: occurredAt,
                submittedAt: Date(),
                runtime: recoveryRuntime(),
                category: "Bug",
                description: String(description.prefix(4_000)),
                diagnostics: recoveryDiagnostics(),
                screenshotCapture: .disabledByConfiguration,
                screenshotMasking: .notApplicable,
                customContext: settings.customContext,
                policyStatus: settings.policyStatus,
                workspacePolicyVersion: settings.workspacePolicyVersion,
                javascriptCrash: reportCrash
            )

            do {
                let envelope = try CrumbReportEnvelopeBuilder.build(settings: settings, input: input)
                _ = try await CrumbReportQueue.shared.enqueue(envelope: envelope, artifacts: [])
                if store.remove(recordID: crash.recordID) {
                    recovered = true
                }
            } catch {
                // Queue-full, corruption, or storage errors leave the crash
                // occurrence pending for a later launch.
            }
        }
        return recovered
    }

    private static func recoveryReportID(for recordID: String) -> String {
        "rpt_" + String(recordID.dropFirst(4))
    }

    private static func recoveryRuntime() -> CrumbReportRuntime {
        #if os(iOS)
        let deviceFamily = "iOS"
        #else
        let deviceFamily = "Apple"
        #endif
        return CrumbReportRuntime(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString.prefix(64).description,
            deviceFamily: deviceFamily,
            locale: Locale.current.identifier.prefix(64).description,
            timezone: TimeZone.current.identifier.prefix(128).description
        )
    }

    private static func recoveryDiagnostics() -> CrumbDiagnosticsSnapshot {
        CrumbDiagnosticsSnapshot(
            capturedAt: Date(),
            location: "react_native_recovery",
            processName: "react-native",
            processID: ProcessInfo.processInfo.processIdentifier,
            cpuUsagePercent: nil,
            residentMemoryBytes: nil,
            physicalFootprintBytes: nil,
            thermalState: "unavailable",
            threadCount: 0,
            busiestThreads: [],
            gpuStatus: "unavailable",
            network: CrumbNetworkDiagnostic(
                status: "unknown",
                transport: "unknown",
                cellularGeneration: nil,
                isExpensive: false,
                isConstrained: false,
                healthCheck: nil
            ),
            logs: CrumbLogDiagnostic(
                status: .unavailable,
                sources: [],
                entries: [],
                truncated: false,
                droppedEntryCount: 0,
                failures: []
            ),
            stackTraces: CrumbStackTraceDiagnostic(
                status: .unavailable,
                scope: "none",
                threads: [],
                truncated: false,
                unavailableReason: "unavailable_during_recovery"
            )
        )
    }
}
