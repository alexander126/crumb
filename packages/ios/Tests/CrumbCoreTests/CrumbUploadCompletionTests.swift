import CryptoKit
import Foundation
import Testing
@testable import CrumbCore

struct CrumbUploadCompletionTests {
    @Test(arguments: [
        (202, #"{"status":"processing"}"#),
        (200, #"{"status":"initialized"}"#),
        (200, #"{"detail":"synthetic-response-detail https://response.example.invalid"}"#),
        (200, #"{"status":null}"#),
        (200, #"{"status":202}"#),
        (200, #"{"status":true}"#),
        (200, #"{"status":["accepted"]}"#),
        (200, #"{"status":"Accepted"}"#),
        (200, #"{"status":" accepted "}"#),
        (200, #"[{"status":"accepted"}]"#),
        (200, #""accepted""#),
        (200, "null"),
        (200, ""),
        (200, #"{"status":"#),
        (200, #"{"status":"accepted"} trailing-data"#),
        (200, "{\"status\":\"accepted\"}\u{0000}"),
        (200, "{\"status\":\"accepted\"}\u{0001}"),
        (200, #"{"status":"accepted"} {"status":"processing"}"#),
        (200, #"{"status":"accepted","report_id":"rpt_OtherAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#),
        (200, #"{"status":"accepted","report_id":null}"#),
        (200, #"{"status":"accepted","report_id":42}"#),
        (200, #"{"status":"accepted","report_id":true}"#),
        (200, #"{"status":"accepted","report_id":{}}"#),
        (200, #"{"status":"accepted","report_id":[]}"#)
    ])
    func invalidCompletionPreservesTheOwnedReport(statusCode: Int, body: String) async throws {
        try await assertPreservedCompletion(statusCode: statusCode, body: body)
    }

    @Test
    func alreadyAcceptedInitializationStillRequiresAcceptedCompletion() async throws {
        try await assertPreservedCompletion(
            statusCode: 202, body: #"{"status":"processing"}"#, alreadyAccepted: true
        )
    }

    @Test(arguments: [
        (200, #"{"status":"accepted"}"#, false),
        (202, #"{"status":"accepted"}"#, false),
        (200, " \t\r\n{\"status\":\"accepted\"} \t\r\n", false),
        (200, #"{"status":"accepted","extra":"\u0000"}"#, false),
        (200, #"{"status":"accepted","report_id":"rpt_CompletionAAAAAAAAAAAAAAAAAAAAAA"}"#, false),
        (200, #"{"status":"accepted"}"#, true),
        (202, #"{"status":"accepted","report_id":"rpt_CompletionAAAAAAAAAAAAAAAAAAAAAA","extra":{"value":null}}"#, true)
    ])
    func acceptedCompletionRemovesTheReportExactlyOnce(
        statusCode: Int, body: String, alreadyAccepted: Bool
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let settings = try makeSettings()
        let queue = ownedQueue(root: root, settings: settings)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        let transport = CompletionTransport(
            artifact: fixture.artifact, completion: .init(statusCode: statusCode, data: Data(body.utf8)),
            alreadyAccepted: alreadyAccepted
        )
        let worker = CrumbReportUploadWorker(queue: queue, settings: settings, transport: transport)

        let result = await worker.runPass()
        let secondPass = await worker.runPass()

        #expect(result.uploadedReportCount == 1)
        #expect(result.remainingReportCount == 0)
        #expect(!result.shouldRetry)
        #expect(secondPass.uploadedReportCount == 0)
        #expect(try await queue.reports().isEmpty)
        let counts = await transport.counts()
        #expect(counts.initializations == 1)
        #expect(counts.artifacts == (alreadyAccepted ? 0 : 1))
        #expect(counts.completions == 1)
    }

    @Test(arguments: [(408, true), (429, true), (500, true), (401, false)])
    func completionHttpFailuresKeepTheirExistingRetryClassification(
        statusCode: Int, retryable: Bool
    ) async throws {
        try await assertPreservedCompletion(
            statusCode: statusCode, body: #"{"status":"accepted"}"#,
            expectedError: "complete.http_\(statusCode)", shouldRetry: retryable
        )
    }

    private func assertPreservedCompletion(
        statusCode: Int, body: String, alreadyAccepted: Bool = false,
        expectedError: String = "complete.invalid_response", shouldRetry: Bool = false
    ) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let settings = try makeSettings()
        let queue = ownedQueue(root: root, settings: settings)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        let before = try await queue.load(reportID: fixture.envelope.reportID)
        let transport = CompletionTransport(
            artifact: fixture.artifact, completion: .init(statusCode: statusCode, data: Data(body.utf8)),
            alreadyAccepted: alreadyAccepted
        )

        let result = await CrumbReportUploadWorker(
            queue: queue, settings: settings, transport: transport
        ).runPass()

        #expect(result.uploadedReportCount == 0)
        #expect(result.remainingReportCount == 1)
        #expect(result.shouldRetry == shouldRetry)
        #expect(!result.wasCancelled)
        let counts = await transport.counts()
        #expect(counts.initializations == 1)
        #expect(counts.artifacts == (alreadyAccepted ? 0 : 1))
        #expect(counts.completions == 1)
        let restarted = ownedQueue(root: root, settings: settings)
        let retained = try await restarted.load(reportID: fixture.envelope.reportID)
        #expect(retained.envelope == before.envelope)
        #expect(retained.artifacts == before.artifacts)
        #expect(retained.summary.state == .failed)
        #expect(retained.summary.attemptCount == 1)
        #expect(retained.summary.lastError == expectedError)
        #expect(retained.summary.totalByteSize == before.summary.totalByteSize)
        #expect(retained.summary.artifactCount == 1)
        let recordData = try Data(contentsOf: root.appendingPathComponent(fixture.envelope.reportID)
            .appendingPathComponent("record.json"))
        let record = try #require(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        #expect(record["schemaVersion"] as? Int == 2)
        #expect(record["ownerFingerprint"] as? String == CrumbQueueOwnerFingerprint.make(
            projectKey: settings.projectKey, ingestionURL: settings.ingestionURL
        ))
        let metadata = String(decoding: recordData, as: UTF8.self)
        #expect(!metadata.contains(settings.projectKey))
        #expect(!metadata.contains(settings.ingestionURL.absoluteString))
        #expect(!metadata.contains("synthetic-response-detail"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("crumb-completion-\(UUID().uuidString)")
    }

    private func makeSettings() throws -> CrumbUploadSettings {
        CrumbUploadSettings(
            projectKey: "synthetic_completion_write_key",
            ingestionURL: try #require(URL(string: "https://completion.example.invalid"))
        )
    }

    private func ownedQueue(root: URL, settings: CrumbUploadSettings) -> CrumbReportQueue {
        CrumbReportQueue(rootURL: root, ownerFingerprint: CrumbQueueOwnerFingerprint.make(
            projectKey: settings.projectKey, ingestionURL: settings.ingestionURL
        ))
    }

    private func makeFixture() throws -> (envelope: CrumbSerializedReportEnvelope, artifact: CrumbQueueArtifact) {
        let reportID = "rpt_CompletionAAAAAAAAAAAAAAAAAAAAAA"
        let bytes = Data("synthetic masked screenshot".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = CrumbArtifactManifest(
            id: "art_0123456789ABCDEF", kind: "screenshot", mimeType: "image/png",
            byteSize: bytes.count, sha256: digest, redactionState: "masked", uploadID: "upl_0123456789ABCDEF"
        )
        let envelope = try JSONSerialization.data(withJSONObject: [
            "schema_version": "1.0", "report_id": reportID,
            "artifacts": [[
                "id": manifest.id, "kind": manifest.kind, "mime_type": manifest.mimeType,
                "byte_size": manifest.byteSize, "sha256": manifest.sha256,
                "redaction_state": manifest.redactionState, "upload_id": manifest.uploadID
            ]]
        ], options: [.sortedKeys])
        return (
            CrumbSerializedReportEnvelope(reportID: reportID, submittedAt: Date(timeIntervalSince1970: 1_700_000_000), data: envelope),
            CrumbQueueArtifact(manifest: manifest, data: bytes)
        )
    }
}

private actor CompletionTransport: CrumbUploadTransport {
    private let artifact: CrumbQueueArtifact
    private let completion: CrumbUploadHTTPResponse
    private let alreadyAccepted: Bool
    private var initializations = 0
    private var artifacts = 0
    private var completions = 0

    init(artifact: CrumbQueueArtifact, completion: CrumbUploadHTTPResponse, alreadyAccepted: Bool) {
        self.artifact = artifact
        self.completion = completion
        self.alreadyAccepted = alreadyAccepted
    }

    func counts() -> (initializations: Int, artifacts: Int, completions: Int) {
        (initializations, artifacts, completions)
    }

    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        if request.url?.path.hasSuffix("/init") == true {
            initializations += 1
            let targets: [[String: Any]] = alreadyAccepted ? [] : [[
                "id": artifact.manifest.id, "upload_id": artifact.manifest.uploadID, "method": "PUT",
                "url": "https://objects.example.invalid/synthetic", "headers": ["content-type": "image/png"]
            ]]
            return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: [
                "report_id": "rpt_CompletionAAAAAAAAAAAAAAAAAAAAAA",
                "status": alreadyAccepted ? "accepted" : "initialized", "artifacts": targets
            ]))
        }
        if request.httpMethod == "PUT" {
            artifacts += 1
            #expect(request.httpBody == artifact.data)
            return .init(statusCode: 200)
        }
        completions += 1
        #expect(request.url?.path.hasSuffix("/complete") == true)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "rpt_CompletionAAAAAAAAAAAAAAAAAAAAAA:complete")
        return completion
    }
}
