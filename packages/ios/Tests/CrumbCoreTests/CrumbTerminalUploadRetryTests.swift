import CryptoKit
import Foundation
import Testing
@testable import CrumbCore

struct CrumbTerminalUploadRetryTests {
    @Test(arguments: ["http422", "invalidComplete"])
    func automaticPassDoesNotReofferTerminalReportWhenSiblingRetries(terminal: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crumb-terminal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = CrumbUploadSettings(projectKey: "synthetic-terminal-key", ingestionURL: try #require(URL(string: "https://ingestion.example.invalid")))
        let owner = CrumbQueueOwnerFingerprint.make(projectKey: settings.projectKey, ingestionURL: settings.ingestionURL)
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        let oldest = try fixture("rpt_TerminalAAAAAAAAAAAAAAAAAAAAAAAAA", offset: 0)
        let sibling = try fixture("rpt_TransientBBBBBBBBBBBBBBBBBBBBBBBB", offset: 1)
        for item in [oldest, sibling] {
            try await queue.enqueue(envelope: item.0, artifacts: [item.1])
        }
        let transport = TerminalRetryTransport(terminalID: oldest.0.reportID, transientID: sibling.0.reportID, invalidCompletion: terminal == "invalidComplete")
        let worker = CrumbReportUploadWorker(queue: queue, settings: settings, transport: transport)

        let first = await worker.runPass()
        #expect(first.shouldRetry)
        let failed = try await queue.load(reportID: oldest.0.reportID)
        #expect(failed.summary.state == .failed)
        #expect(failed.summary.attemptCount == 1)
        #expect(failed.summary.lastError == (terminal == "invalidComplete" ? "complete.invalid_response" : "init.http_422"))
        let recordURL = root.appendingPathComponent(oldest.0.reportID).appendingPathComponent("record.json")
        let record = try Data(contentsOf: recordURL)

        let automatic = await worker.runPass()

        #expect(automatic.shouldRetry)
        #expect(automatic.remainingReportCount == 2)
        #expect(await transport.initializations(oldest.0.reportID) == 1)
        #expect(await transport.initializations(sibling.0.reportID) == 2)
        #expect(try await queue.load(reportID: oldest.0.reportID) == failed)
        #expect(try Data(contentsOf: recordURL) == record)
        #expect(try await queue.load(reportID: sibling.0.reportID).summary.attemptCount == 2)

        await transport.allowTransientReport()
        let newReport = try fixture("rpt_NewCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", offset: 2)
        try await queue.enqueue(envelope: newReport.0, artifacts: [newReport.1])
        let progress = await worker.runPass()
        #expect(progress.uploadedReportCount == 2)
        #expect(progress.remainingReportCount == 1)
        #expect(!progress.shouldRetry)
        #expect(await transport.initializations(oldest.0.reportID) == 1)
        #expect(try await queue.load(reportID: oldest.0.reportID) == failed)

        // Failed enumeration must not discard the remembered terminal
        // classification. The failure has to be genuine I/O: malformed metadata
        // is now isolated per item rather than failing the scan, and a
        // permission-based injection would not hold when tests run as root.
        // A directory where the metadata file belongs makes the read fail for
        // every uid.
        try FileManager.default.removeItem(at: recordURL)
        try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: false)
        #expect(await worker.runPass().shouldRetry)
        try FileManager.default.removeItem(at: recordURL)
        try record.write(to: recordURL)
        #expect(!(await worker.runPass()).shouldRetry)
        #expect(await transport.initializations(oldest.0.reportID) == 1)

        await worker.prepareForForegroundPass()
        let foreground = await worker.runPass()
        #expect(!foreground.shouldRetry)
        #expect(foreground.remainingReportCount == 1)
        #expect(await transport.initializations(oldest.0.reportID) == 2)
        #expect(try await queue.load(reportID: oldest.0.reportID).summary.attemptCount == 2)

        // An explicit pending transition or a genuinely new entry with the same ID is eligible.
        try await queue.markPending(reportID: oldest.0.reportID)
        _ = await worker.runPass()
        #expect(await transport.initializations(oldest.0.reportID) == 3)
        try await queue.remove(reportID: oldest.0.reportID)
        try await queue.enqueue(envelope: oldest.0, artifacts: [oldest.1])
        _ = await worker.runPass()
        #expect(await transport.initializations(oldest.0.reportID) == 4)
        #expect(try await queue.load(reportID: oldest.0.reportID).summary.attemptCount == 1)
    }

    private func fixture(_ reportID: String, offset: TimeInterval) throws -> (CrumbSerializedReportEnvelope, CrumbQueueArtifact) {
        let data = Data("synthetic masked screenshot".utf8)
        let manifest = CrumbArtifactManifest(id: "art_0123456789ABCDEF", kind: "screenshot", mimeType: "image/png", byteSize: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), redactionState: "masked", uploadID: "upl_0123456789ABCDEF")
        let envelope = try JSONSerialization.data(withJSONObject: ["schema_version": "1.0", "report_id": reportID, "artifacts": [[
            "id": manifest.id, "kind": manifest.kind, "mime_type": manifest.mimeType, "byte_size": manifest.byteSize,
            "sha256": manifest.sha256, "redaction_state": manifest.redactionState, "upload_id": manifest.uploadID
        ]]], options: [.sortedKeys])
        return (.init(reportID: reportID, submittedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset), data: envelope), .init(manifest: manifest, data: data))
    }
}

private actor TerminalRetryTransport: CrumbUploadTransport {
    let terminalID: String
    let transientID: String
    let invalidCompletion: Bool
    private var counts: [String: Int] = [:]
    private var transientAllowed = false

    init(terminalID: String, transientID: String, invalidCompletion: Bool) {
        self.terminalID = terminalID
        self.transientID = transientID
        self.invalidCompletion = invalidCompletion
    }

    func initializations(_ reportID: String) -> Int { counts[reportID, default: 0] }
    func allowTransientReport() { transientAllowed = true }

    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        if request.url?.path.hasSuffix("/init") == true {
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let envelope = try #require(body["envelope"] as? [String: Any])
            let id = try #require(envelope["report_id"] as? String)
            counts[id, default: 0] += 1
            if id == transientID && !transientAllowed { return .init(statusCode: 503) }
            if id == terminalID && !invalidCompletion { return .init(statusCode: 422) }
            return .init(statusCode: 201, data: try JSONSerialization.data(withJSONObject: ["report_id": id, "status": "initialized", "artifacts": [[
                "id": "art_0123456789ABCDEF", "upload_id": "upl_0123456789ABCDEF", "method": "PUT", "url": "https://objects.example.invalid/synthetic", "headers": [String: String]()
            ]]]))
        }
        if request.httpMethod == "PUT" { return .init(statusCode: 200) }
        #expect(request.url?.path.hasSuffix("/complete") == true)
        let isTerminal = request.url?.path.contains(terminalID) == true
        return .init(statusCode: 202, data: Data((isTerminal ? #"{"status":"processing"}"# : #"{"status":"accepted"}"#).utf8))
    }
}
