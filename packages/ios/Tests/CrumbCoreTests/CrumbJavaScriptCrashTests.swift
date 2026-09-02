import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbJavaScriptCrashTests {
    @Test
    func sanitizesAndDeduplicatesJavaScriptAndNativeWrapperOccurrences() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrumbJavaScriptCrashStore(rootURL: root)
        let settings = makeSettings()
        let first = CrumbJavaScriptCrash(
            kind: .fatalException,
            errorType: "TypeError",
            message: "Authorization: Bearer secret email=user@example.invalid",
            rawStack: "TypeError: failed\n    at checkout (Checkout.tsx:42:7)",
            fingerprint: "js_shared",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            breadcrumbs: [
                CrumbJavaScriptBreadcrumb(
                    timestamp: Date(timeIntervalSince1970: 1_699_999_999),
                    category: "checkout",
                    message: "started"
                )
            ]
        )
        let wrapper = CrumbJavaScriptCrash(
            kind: .fatalException,
            source: .nativeTerminationWrapper,
            errorType: "NativeTermination",
            message: "native wrapper",
            fingerprint: "js_shared",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001),
            nativeTerminationWrapper: true
        )

        #expect(store.record(first, settings: settings))
        #expect(store.record(wrapper, settings: settings))

        let records = store.records()
        #expect(records.count == 1)
        #expect(records[0].crash.source == .javascript)
        #expect(records[0].crash.nativeTerminationWrapper)
        #expect(records[0].crash.message.contains("[REDACTED]"))
        #expect(!records[0].crash.message.contains("secret"))
        #expect(!records[0].crash.message.contains("user@example.invalid"))
        #expect(records[0].crash.rawStack?.contains("\n") == true)
    }

    @Test
    func recoversIntoTheDurableQueueAndDoesNotDuplicateAfterRelaunch() async throws {
        let storeRoot = temporaryRoot()
        let queueRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: storeRoot)
            try? FileManager.default.removeItem(at: queueRoot)
        }
        let store = CrumbJavaScriptCrashStore(rootURL: storeRoot)
        let queue = CrumbReportQueue(rootURL: queueRoot)
        let settings = makeSettings()
        let crash = CrumbJavaScriptCrash(
            kind: .unhandledRejection,
            errorType: "Error",
            message: "Promise rejected",
            rawStack: "Error: Promise rejected\n    at loadData (data.ts:10:2)",
            fingerprint: "js_recovery",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(store.record(crash, settings: settings))

        let runtime = CrumbReportRuntime(
            osVersion: "18.0",
            deviceFamily: "iPhone",
            locale: "en-US",
            timezone: "UTC"
        )
        #expect(
            await CrumbJavaScriptCrashRecovery.recoverPending(
                store: store,
                queue: queue,
                settings: settings,
                runtime: runtime
            ) == 1
        )
        #expect(store.records().isEmpty)
        let reports = try await queue.reports()
        #expect(reports.count == 1)
        let payload = try await queue.load(reportID: reports[0].reportID)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: payload.envelope) as? [String: Any]
        )
        #expect(envelope["trigger"] as? String == "javascript_crash")
        #expect(envelope["javascript_crash"] != nil)
        #expect(
            (envelope["privacy"] as? [String: Any])?["diagnostics_capture"] as? String
                == "crash_recovery"
        )

        #expect(
            await CrumbJavaScriptCrashRecovery.recoverPending(
                store: store,
                queue: queue,
                settings: settings,
                runtime: runtime
            ) == 0
        )
        #expect(try await queue.reports().count == 1)
    }

    @Test
    func keepsThePendingHandoffWhenTheReportQueueIsFull() async throws {
        let storeRoot = temporaryRoot()
        let queueRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: storeRoot)
            try? FileManager.default.removeItem(at: queueRoot)
        }
        let store = CrumbJavaScriptCrashStore(rootURL: storeRoot)
        let queue = CrumbReportQueue(
            rootURL: queueRoot,
            limits: CrumbQueueLimits(
                maximumReports: 1,
                maximumTotalBytes: 4_096,
                maximumReportBytes: 4_096,
                maximumEnvelopeBytes: 2_048,
                maximumArtifactBytes: 1_024,
                maximumArtifactsPerReport: 0
            )
        )
        let existingID = "rpt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let existingData = try JSONSerialization.data(withJSONObject: [
            "report_id": existingID,
            "artifacts": []
        ], options: [.sortedKeys])
        try await queue.enqueue(
            envelope: CrumbSerializedReportEnvelope(
                reportID: existingID,
                submittedAt: Date(timeIntervalSince1970: 1_700_000_000),
                data: existingData
            ),
            artifacts: []
        )
        let settings = makeSettings()
        #expect(
            store.record(
                CrumbJavaScriptCrash(
                    kind: .fatalException,
                    errorType: "Error",
                    message: "queue full",
                    fingerprint: "js_full"
                ),
                settings: settings
            )
        )

        #expect(
            await CrumbJavaScriptCrashRecovery.recoverPending(
                store: store,
                queue: queue,
                settings: settings,
                runtime: CrumbReportRuntime(
                    osVersion: "18.0",
                    deviceFamily: "iPhone",
                    locale: "en-US",
                    timezone: "UTC"
                )
            ) == 0
        )
        #expect(store.records().count == 1)
        #expect(try await queue.reports().count == 1)
    }

    @Test
    func ignoresCorruptPendingStorageAndEnforcesRecordLimit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("pending-javascript-crashes.json")
        )
        let store = CrumbJavaScriptCrashStore(rootURL: root)
        let settings = makeSettings()

        #expect(store.records().isEmpty)
        for index in 0..<CrumbJavaScriptCrashStore.maximumRecords {
            #expect(
                store.record(
                    CrumbJavaScriptCrash(
                        kind: .unhandledRejection,
                        errorType: "Error",
                        message: "failure \(index)",
                        fingerprint: "js_limit_\(index)"
                    ),
                    settings: settings
                )
            )
        }
        #expect(
            !store.record(
                CrumbJavaScriptCrash(
                    kind: .unhandledRejection,
                    errorType: "Error",
                    message: "failure over limit",
                    fingerprint: "js_limit_over"
                ),
                settings: settings
            )
        )
        #expect(store.records().count == CrumbJavaScriptCrashStore.maximumRecords)
    }

    private func makeSettings() -> CrumbReportSettings {
        CrumbReportSettings(
            environment: "test",
            release: CrumbRelease(appVersion: "1.0.0", nativeBuild: "1"),
            invocation: [.programmatic],
            capture: CrumbCaptureOptions(),
            diagnostics: CrumbDiagnosticsOptions(),
            privacy: CrumbPrivacyOptions(),
            reporter: CrumbReporterOptions(),
            evidence: [.customContext],
            application: CrumbApplicationMetadata(name: "Example"),
            customContext: ["account_tier": "trial"],
            policyStatus: .notConfigured,
            workspacePolicyVersion: nil
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crumb-javascript-crash-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
