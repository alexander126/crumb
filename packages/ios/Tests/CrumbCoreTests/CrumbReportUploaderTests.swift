import CryptoKit
import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbReportUploaderTests {
    @Test
    func preservesAnUnownedReportWithoutSendingReplacementCredentials() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let queue = CrumbReportQueue(rootURL: root)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        let recordURL = root.appendingPathComponent(fixture.envelope.reportID)
            .appendingPathComponent("record.json")
        let beforeRecord = try Data(contentsOf: recordURL)
        let beforePayload = try await queue.load(reportID: fixture.envelope.reportID)
        let transport = CountingRejectedTransport()
        let replacementWorker = CrumbReportUploadWorker(
            queue: queue,
            settings: CrumbUploadSettings(
                projectKey: "synthetic_replacement_write_key",
                ingestionURL: try #require(URL(string: "https://replacement.example.invalid"))
            ),
            transport: transport
        )

        let result = await replacementWorker.runPass()

        #expect(await transport.requestCount() == 0)
        #expect(result.uploadedReportCount == 0)
        #expect(result.remainingReportCount == 0)
        #expect(!result.shouldRetry)
        #expect(try Data(contentsOf: recordURL) == beforeRecord)
        #expect(try await queue.load(reportID: fixture.envelope.reportID) == beforePayload)
    }

    @Test
    func offlineReportUploadsExactlyOnceAfterConnectivityReturns() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let settings = try makeSettings()
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: CrumbQueueOwnerFingerprint.make(
            projectKey: settings.projectKey, ingestionURL: settings.ingestionURL
        ))
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
            settings: settings,
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
        let settings = try makeSettings()
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: CrumbQueueOwnerFingerprint.make(
            projectKey: settings.projectKey, ingestionURL: settings.ingestionURL
        ))
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        let transport = BlockingTransport()
        let worker = CrumbReportUploadWorker(
            queue: queue,
            settings: settings,
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

    @Test(arguments: ["key", "host", "path", "port", "scheme", "local-only", "trailing-separator"])
    func preservesForeignReportsIncludingInterruptedUploadState(change: String) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let original = try makeSettings()
        let originalOwner = CrumbQueueOwnerFingerprint.make(
            projectKey: original.projectKey,
            ingestionURL: change == "local-only" ? nil : original.ingestionURL
        )
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: originalOwner)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        try await queue.markUploading(reportID: fixture.envelope.reportID)
        let beforePayload = try await queue.load(reportID: fixture.envelope.reportID)
        let recordURL = root.appendingPathComponent(fixture.envelope.reportID).appendingPathComponent("record.json")
        let beforeRecord = try Data(contentsOf: recordURL)
        let replacementURL: String
        switch change {
        case "host": replacementURL = "https://other.example.invalid"
        case "path": replacementURL = "https://ingestion.example.test/other"
        case "port": replacementURL = "https://ingestion.example.test:8443"
        case "scheme": replacementURL = "http://ingestion.example.test"
        case "trailing-separator": replacementURL = "https://ingestion.example.test//"
        default: replacementURL = original.ingestionURL.absoluteString
        }
        let replacement = try makeSettings(
            projectKey: change == "key" ? "synthetic_replacement_key" : original.projectKey,
            ingestionURL: replacementURL
        )
        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: CrumbQueueOwnerFingerprint.make(
            projectKey: replacement.projectKey, ingestionURL: replacement.ingestionURL
        ))
        let transport = CountingRejectedTransport()
        let worker = CrumbReportUploadWorker(queue: restarted, settings: replacement, transport: transport)

        // Reporter installation and the upload pass must both leave foreign state untouched.
        try await restarted.recoverInterruptedUploads()
        let result = await worker.runPass()

        #expect(await transport.requestCount() == 0)
        #expect(result.remainingReportCount == 0)
        #expect(!result.shouldRetry)
        #expect(try Data(contentsOf: recordURL) == beforeRecord)
        #expect(try await restarted.load(reportID: fixture.envelope.reportID) == beforePayload)
        #expect(try await restarted.reports().count == 1)
    }

    @Test(arguments: [false, true])
    func neverAdoptsLegacyRecordsEvenWithAnInjectedOwnershipField(injectedOwner: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let settings = try makeSettings()
        let owner = CrumbQueueOwnerFingerprint.make(projectKey: settings.projectKey, ingestionURL: settings.ingestionURL)
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        try await queue.markUploading(reportID: fixture.envelope.reportID)
        let recordURL = root.appendingPathComponent(fixture.envelope.reportID).appendingPathComponent("record.json")
        var metadata = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        metadata["schemaVersion"] = 1
        if !injectedOwner { metadata.removeValue(forKey: "ownerFingerprint") }
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: recordURL)
        let beforeRecord = try Data(contentsOf: recordURL)
        let beforePayload = try await queue.load(reportID: fixture.envelope.reportID)
        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        let transport = CountingRejectedTransport()

        try await restarted.recoverInterruptedUploads()
        let result = await CrumbReportUploadWorker(queue: restarted, settings: settings, transport: transport).runPass()

        #expect(await transport.requestCount() == 0)
        #expect(result.remainingReportCount == 0)
        #expect(!result.shouldRetry)
        #expect(try Data(contentsOf: recordURL) == beforeRecord)
        #expect(try await restarted.load(reportID: fixture.envelope.reportID) == beforePayload)
    }

    @Test
    func matchingOwnerRecoversAfterRestartAndCompletesDelivery() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let settings = try makeSettings()
        let owner = CrumbQueueOwnerFingerprint.make(projectKey: settings.projectKey, ingestionURL: settings.ingestionURL)
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        try await queue.markUploading(reportID: fixture.envelope.reportID)
        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        let transport = ConnectivityTransport(
            reportID: fixture.envelope.reportID,
            artifactID: fixture.artifact.manifest.id,
            uploadID: fixture.artifact.manifest.uploadID,
            envelopeByteCount: fixture.envelope.data.count,
            artifactByteCount: fixture.artifact.data.count
        )
        await transport.setOnline(true)

        let result = await CrumbReportUploadWorker(queue: restarted, settings: settings, transport: transport).runPass()
        let counts = await transport.counts()

        #expect(result.uploadedReportCount == 1)
        #expect(result.remainingReportCount == 0)
        #expect(counts.initRequests == 1)
        #expect(counts.artifactUploads == 1)
        #expect(counts.completions == 1)
        #expect(try await restarted.reports().isEmpty)
    }

    private func makeSettings(
        projectKey: String = "write_test_key",
        ingestionURL: String = "https://ingestion.example.test"
    ) throws -> CrumbUploadSettings {
        CrumbUploadSettings(projectKey: projectKey, ingestionURL: try #require(URL(string: ingestionURL)))
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
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.httpBody == Data("{}".utf8))
            return CrumbUploadHTTPResponse(statusCode: 200, data: Data(#"{"status":"accepted"}"#.utf8))
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

private actor CountingRejectedTransport: CrumbUploadTransport {
    private var requests = 0

    func requestCount() -> Int { requests }

    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        requests += 1
        throw URLError(.notConnectedToInternet)
    }
}
