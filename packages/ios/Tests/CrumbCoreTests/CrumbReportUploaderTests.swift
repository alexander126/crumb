import CryptoKit
import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbReportUploaderTests {
    @Test
    func offlineReportUploadsExactlyOnceAfterConnectivityReturns() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let queue = CrumbReportQueue(rootURL: root)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])

        let transport = ConnectivityTransport(
            reportID: fixture.envelope.reportID,
            artifactID: fixture.artifact.manifest.id,
            uploadID: fixture.artifact.manifest.uploadID,
            envelopeByteCount: fixture.envelope.data.count,
            artifactByteCount: fixture.artifact.data.count
        )
        let worker = CrumbReportUploadWorker(
            queue: queue,
            settings: CrumbUploadSettings(
                projectKey: "write_test_key",
                ingestionURL: try #require(URL(string: "https://ingestion.example.test"))
            ),
            transport: transport
        )

        let offline = await worker.runPass()
        #expect(offline.uploadedReportCount == 0)
        #expect(offline.remainingReportCount == 1)
        #expect(offline.shouldRetry)
        let failed = try #require(try await queue.reports().first)
        #expect(failed.state == .failed)
        #expect(failed.attemptCount == 1)
        #expect(failed.lastError == "init.network")

        await transport.setOnline(true)
        let reconnected = await worker.runPass()
        let drainedAgain = await worker.runPass()
        let counts = await transport.counts()

        #expect(reconnected.uploadedReportCount == 1)
        #expect(reconnected.remainingReportCount == 0)
        #expect(!reconnected.shouldRetry)
        #expect(drainedAgain.uploadedReportCount == 0)
        #expect(counts.initRequests == 2)
        #expect(counts.artifactUploads == 1)
        #expect(counts.completions == 1)
        #expect(try await queue.reports().isEmpty)
    }

    @Test
    func cancellingAnInFlightPassReturnsTheReportToPending() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(reportID: "rpt_CancelAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let queue = CrumbReportQueue(rootURL: root)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        let transport = BlockingTransport()
        let worker = CrumbReportUploadWorker(
            queue: queue,
            settings: CrumbUploadSettings(
                projectKey: "write_test_key",
                ingestionURL: try #require(URL(string: "https://ingestion.example.test"))
            ),
            transport: transport
        )

        let task = Task { await worker.runPass() }
        while !(await transport.hasStarted()) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        let result = await task.value
        let summary = try #require(try await queue.reports().first)

        #expect(result.wasCancelled)
        #expect(summary.state == .pending)
        #expect(summary.attemptCount == 1)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crumb-uploader-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFixture(
        reportID: String = "rpt_OfflineAAAAAAAAAAAAAAAAAAAAAAAAA"
    ) throws -> (envelope: CrumbSerializedReportEnvelope, artifact: CrumbQueueArtifact) {
        let artifactData = Data("masked-png".utf8)
        let digest = SHA256.hash(data: artifactData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = CrumbArtifactManifest(
            id: "art_0123456789ABCDEF",
            kind: "screenshot",
            mimeType: "image/png",
            byteSize: artifactData.count,
            sha256: digest,
            redactionState: "masked",
            uploadID: "upl_0123456789ABCDEF"
        )
        let envelopeData = try JSONSerialization.data(withJSONObject: [
            "schema_version": "1.0",
            "report_id": reportID,
            "artifacts": [[
                "id": manifest.id,
                "kind": manifest.kind,
                "mime_type": manifest.mimeType,
                "byte_size": manifest.byteSize,
                "sha256": manifest.sha256,
                "redaction_state": manifest.redactionState,
                "upload_id": manifest.uploadID
            ]]
        ], options: [.sortedKeys])
        return (
            CrumbSerializedReportEnvelope(
                reportID: reportID,
                submittedAt: Date(timeIntervalSince1970: 1_700_000_000),
                data: envelopeData
            ),
            CrumbQueueArtifact(manifest: manifest, data: artifactData)
        )
    }
}

private actor ConnectivityTransport: CrumbUploadTransport {
    private let reportID: String
    private let artifactID: String
    private let uploadID: String
    private let envelopeByteCount: Int
    private let artifactByteCount: Int
    private var online = false
    private var initRequests = 0
    private var artifactUploads = 0
    private var completions = 0

    init(
        reportID: String,
        artifactID: String,
        uploadID: String,
        envelopeByteCount: Int,
        artifactByteCount: Int
    ) {
        self.reportID = reportID
        self.artifactID = artifactID
        self.uploadID = uploadID
        self.envelopeByteCount = envelopeByteCount
        self.artifactByteCount = artifactByteCount
    }

    func setOnline(_ value: Bool) {
        online = value
    }

    func counts() -> (initRequests: Int, artifactUploads: Int, completions: Int) {
        (initRequests, artifactUploads, completions)
    }

    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        if request.url?.path.hasSuffix("/init") == true {
            initRequests += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer write_test_key")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "\(reportID):init")
            #expect((request.httpBody?.count ?? 0) - envelopeByteCount <= 65_536)
            guard online else { throw URLError(.notConnectedToInternet) }
            let response = try JSONSerialization.data(withJSONObject: [
                "report_id": reportID,
                "status": "initialized",
                "artifacts": [[
                    "id": artifactID,
                    "upload_id": uploadID,
                    "method": "PUT",
                    "url": "https://objects.example.test/signed/\(artifactID)",
                    "headers": ["content-type": "image/png"],
                    "expires_at": "2026-08-24T23:59:59.000Z"
                ]]
            ], options: [.sortedKeys])
            return CrumbUploadHTTPResponse(statusCode: 201, data: response)
        }
        if request.url?.host == "objects.example.test" {
            artifactUploads += 1
            #expect(request.httpBody?.count == artifactByteCount)
            return CrumbUploadHTTPResponse(statusCode: 200)
        }
        if request.url?.path.hasSuffix("/complete") == true {
            completions += 1
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "\(reportID):complete")
            return CrumbUploadHTTPResponse(statusCode: 200)
        }
        return CrumbUploadHTTPResponse(statusCode: 404)
    }
}

private actor BlockingTransport: CrumbUploadTransport {
    private var started = false

    func hasStarted() -> Bool { started }

    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        started = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return CrumbUploadHTTPResponse(statusCode: 500)
    }
}
