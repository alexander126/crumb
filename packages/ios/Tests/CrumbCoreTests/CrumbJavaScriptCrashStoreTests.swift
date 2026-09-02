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
