import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbJavaScriptCrashStoreTests {
    @Test
    func deduplicatesNativeTerminationWrapperWithoutLosingJavaScriptCause() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrumbJavaScriptCrashStore(rootURL: root)

        #expect(store.record(recordJSON(source: "javascript", kind: "exception")))
        #expect(store.record(recordJSON(source: "native_termination_wrapper", kind: "native_termination_wrapper")))

        let records = store.records()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.source == "javascript")
        #expect(record.kind == "exception")
        #expect(record.type == "TypeError")
        #expect(record.message == "JS exploded")
        #expect(record.stack?.contains("bundle.js") == true)
        #expect(record.isFatal)
        #expect(record.nativeTerminationWrapperObserved)
    }

    @Test
    func sanitizesCrashFieldsAndNeverStoresUnallowlistedContext() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrumbJavaScriptCrashStore(rootURL: root)

        #expect(store.record(recordJSON(
            source: "javascript",
            kind: "unhandled_rejection",
            message: "Bearer secret-value user@example.invalid"
        )))

        let record = try #require(store.records().first)
        #expect(record.message.contains("[REDACTED]"))
        #expect(record.message.contains("[REDACTED_EMAIL]"))
        #expect(record.context == ["account_tier": "trial"])
        #expect(record.context["token"] == nil)
        #expect(record.breadcrumbs.count == 1)
    }

    @Test
    func rejectsNewRecordsAtTheBoundWithoutEvictingExistingOccurrences() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrumbJavaScriptCrashStore(
            rootURL: root,
            limits: CrumbJavaScriptCrashStoreLimits(
                maximumRecords: 1,
                maximumTotalBytes: 65_536,
                maximumRecordBytes: 65_536,
                maximumBreadcrumbs: 8,
                maximumBreadcrumbBytes: 4_096
            )
        )

        #expect(store.record(recordJSON(recordID: "jsc_AAAAAAAAAAAAAAAA", fingerprint: "aaaaaaaaaaaaaaaa")))
        #expect(!store.record(recordJSON(recordID: "jsc_BBBBBBBBBBBBBBBB", fingerprint: "bbbbbbbbbbbbbbbb")))
        #expect(store.records().map(\.recordID) == ["jsc_AAAAAAAAAAAAAAAA"])
    }

    @Test
    func skipsCorruptFilesAndRecoversValidOccurrences() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("jsc_corruptcorruptcorrupt.json")
        )
        let store = CrumbJavaScriptCrashStore(rootURL: root)
        #expect(store.record(recordJSON()))

        let records = store.records()
        #expect(records.count == 1)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("jsc_corruptcorruptcorrupt.json").path
        ))
    }

    @Test
    func preservesOriginalFailureContextAcrossRestartAndDeduplication() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = failureContext()
        #expect(CrumbJavaScriptCrashStore(rootURL: root).record(recordJSON(), failureContext: context))
        let reopened = CrumbJavaScriptCrashStore(rootURL: root)
        #expect(reopened.record(recordJSON(source: "native_termination_wrapper", kind: "native_termination_wrapper")))
        let record = try #require(reopened.records().first)
        #expect(record.failureContext == context)
        let diagnostics = try #require(record.failureContext?.diagnostics())
        #expect(diagnostics.processID == 777)
        #expect(diagnostics.capturedAt == context.capturedAt)
        #expect(diagnostics.residentMemoryBytes == 12_000_000)
        #expect(diagnostics.location == "react_native_javascript_failure")
        #expect(diagnostics.network.transport == "wifi")
        #expect(diagnostics.stackTraces.status == .unavailable)
    }

    @Test
    func optionalContextNeverDisplacesTheCoreCrashAtTheSizeLimit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = recordJSON()
        let store = CrumbJavaScriptCrashStore(rootURL: root, limits: .init(maximumRecordBytes: json.utf8.count))
        #expect(store.record(json, failureContext: failureContext()))
        #expect(store.records().count == 1)
        let stored = try Data(contentsOf: root.appendingPathComponent("jsc_0123456789ABCDEF.json"))
        #expect(stored.count <= json.utf8.count)
        #expect(store.records().first?.stack != nil)
    }

    @Test
    func dropsMalformedOptionalContextWithoutDeletingTheFailure() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrumbJavaScriptCrashStore(rootURL: root)
        #expect(store.record(recordJSON(), failureContext: failureContext()))
        let url = root.appendingPathComponent("jsc_0123456789ABCDEF.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["failure_context"] = ["processID": "invalid"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(store.records().count == 1)
        #expect(store.records().first?.failureContext == nil)
    }

    @Test
    func nativeContextCannotBeInjectedByJavaScriptAndDisabledLogsAreNotPersisted() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrumbJavaScriptCrashStore(rootURL: root)
        #expect(store.record(recordJSON(), failureContext: failureContext()))
        let persisted = try String(contentsOf: root.appendingPathComponent("jsc_0123456789ABCDEF.json"), encoding: .utf8)
        #expect(store.remove(recordID: "jsc_0123456789ABCDEF"))
        #expect(store.record(persisted, includeBreadcrumbs: false))
        let crash = try #require(store.records().first)
        #expect(crash.failureContext == nil)
        #expect(crash.breadcrumbs.isEmpty)
    }

    @Test
    func totalStoreBudgetDropsOnlyTheIncomingOptionalSnapshot() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = CrumbJavaScriptCrashStore(rootURL: root)
        #expect(seed.record(recordJSON(), failureContext: failureContext()))
        let existingBytes = try Data(contentsOf: root.appendingPathComponent("jsc_0123456789ABCDEF.json")).count
        let json = recordJSON(recordID: "jsc_AAAAAAAAAAAAAAAA", fingerprint: "aaaaaaaaaaaaaaaa")
        let budget = existingBytes + json.utf8.count
        let constrained = CrumbJavaScriptCrashStore(rootURL: root, limits: .init(
            maximumRecords: 50, maximumTotalBytes: budget, maximumRecordBytes: budget,
            maximumBreadcrumbs: 32, maximumBreadcrumbBytes: 16_384))
        #expect(constrained.record(json, failureContext: failureContext()))
        let records = constrained.records()
        #expect(records.count == 2)
        #expect(records.first(where: { $0.recordID == "jsc_0123456789ABCDEF" })?.failureContext != nil)
        #expect(records.first(where: { $0.recordID == "jsc_AAAAAAAAAAAAAAAA" })?.failureContext == nil)
    }

    @Test
    func stacksSurviveRestartAndAreDroppedBeforeMetricsAtTheRecordLimit() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CrumbJavaScriptCrashStore(rootURL: root)
        #expect(store.record(recordJSON(), failureContext: failureContext()))
        let metricsBytes = try Data(contentsOf: root.appendingPathComponent("jsc_0123456789ABCDEF.json")).count
        #expect(store.remove(recordID: "jsc_0123456789ABCDEF"))
        var context = failureContext()
        context.screenContext = CrumbScreenContext(name: "Checkout", route: ["Shop", "Checkout"], source: "react_navigation")
        context.rendering = CrumbRenderingSnapshot(source: "ios_display_link", sampleCount: 100, slowFrameCount: 2, meanFrameMs: 17, maxFrameMs: 60, lastFrameAgeMs: 20)
        context.stacks = CrumbFailureStacks(threads: [.init(index: 0, name: "Thread 0", state: "capture_thread", frames: ["SyntheticApp + 0x1234"])], truncated: false)
        #expect(store.record(recordJSON(), failureContext: context))
        #expect(CrumbJavaScriptCrashStore(rootURL: root).records().first?.failureContext?.screenContext == context.screenContext)
        #expect(CrumbJavaScriptCrashStore(rootURL: root).records().first?.failureContext?.stacks == context.stacks)
        #expect(CrumbJavaScriptCrashStore(rootURL: root).records().first?.failureContext?.rendering == context.rendering)
        #expect(store.remove(recordID: "jsc_0123456789ABCDEF"))
        let limited = CrumbJavaScriptCrashStore(rootURL: root, limits: .init(maximumRecordBytes: metricsBytes))
        #expect(limited.record(recordJSON(), failureContext: context))
        #expect(limited.records().first?.failureContext?.rendering == nil)
        #expect(limited.records().first?.failureContext?.stacks == nil)
        #expect(limited.records().first?.failureContext?.processID == 777)
        #expect(limited.records().first?.stack != nil)
    }

    private func failureContext() -> CrumbJavaScriptFailureContext {
        .init(capturedAt: Date(timeIntervalSince1970: 1_788_350_400), processName: "SyntheticApp", processID: 777,
              cpuUsagePercent: 0, residentMemoryBytes: 12_000_000, physicalFootprintBytes: 15_000_000,
              threadCount: 12, thermalState: "nominal", networkStatus: "reachable", networkTransport: "wifi",
              networkExpensive: false, networkConstrained: false)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crumb-js-crash-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func recordJSON(
        recordID: String = "jsc_0123456789ABCDEF",
        fingerprint: String = "0123456789abcdef",
        source: String = "javascript",
        kind: String = "exception",
        message: String = "JS exploded"
    ) -> String {
        """
        {
          "schema_version": "1.0",
          "record_id": "\(recordID)",
          "fingerprint": "\(fingerprint)",
          "source": "\(source)",
          "kind": "\(kind)",
          "type": "TypeError",
          "message": "\(message)",
          "stack": "TypeError: JS exploded\\n    at screen (bundle.js:10:4)",
          "occurred_at": "2026-09-02T12:00:00Z",
          "release": {
            "app_version": "1.2.3",
            "native_build": "42",
            "bundle_version": "ota-17"
          },
          "breadcrumbs": [
            {
              "timestamp": "2026-09-02T11:59:59Z",
              "source": "react-native",
              "category": "javascript",
              "message": "checkout started"
            }
          ],
          "context": {
            "account_tier": "trial",
            "token": "should not persist"
          },
          "is_fatal": true,
          "native_termination_wrapper_observed": false
        }
        """
    }
}
