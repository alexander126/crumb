import CryptoKit
import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbReportQueueTests {
    @Test
    func defaultPayloadBudgetsMatchTheReleaseContract() {
        let limits = CrumbQueueLimits()
        #expect(limits.maximumEnvelopeBytes == 1_048_576)
        #expect(limits.maximumArtifactBytes == 26_214_400)
        #expect(limits.maximumReportBytes == 27_262_976)
    }

    @Test
    func committedReportSurvivesAQueueRestartWithoutDuplication() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(reportID: "rpt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

        var queue: CrumbReportQueue? = CrumbReportQueue(rootURL: root)
        let first = try await queue?.enqueue(
            envelope: fixture.envelope,
            artifacts: [fixture.artifact]
        )
        #expect(first?.state == .pending)
        #expect(first?.artifactCount == 1)
        queue = nil // Models process memory disappearing after the atomic commit.

        let restartedQueue = CrumbReportQueue(rootURL: root)
        let recovered = try await restartedQueue.reports()
        let payload = try await restartedQueue.load(reportID: fixture.envelope.reportID)
        let repeated = try await restartedQueue.enqueue(
            envelope: fixture.envelope,
            artifacts: [fixture.artifact]
        )

        #expect(recovered.count == 1)
        #expect(payload.envelope == fixture.envelope.data)
        #expect(payload.artifacts == [fixture.artifact])
        #expect(repeated == recovered.first)
        #expect(try await restartedQueue.reports().count == 1)
    }

    @Test
    func interruptedUploadReturnsToPendingAndFailureStatePersists() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(reportID: "rpt_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        let owner = String(repeating: "a", count: 64)
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        try await queue.markUploading(reportID: fixture.envelope.reportID)

        let restartedQueue = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        try await restartedQueue.recoverInterruptedUploads()
        var summary = try #require(try await restartedQueue.reports().first)
        #expect(summary.state == .pending)
        #expect(summary.attemptCount == 1)

        try await restartedQueue.markFailed(
            reportID: fixture.envelope.reportID,
            reason: "offline\nretry later"
        )
        summary = try #require(try await restartedQueue.reports().first)
        #expect(summary.state == .failed)
        #expect(summary.lastError == "offline retry later")
    }

    @Test
    func queueLimitsRejectNewReportsWithoutEvictingCommittedReports() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = CrumbQueueLimits(
            maximumReports: 1,
            maximumTotalBytes: 2_048,
            maximumReportBytes: 2_048,
            maximumEnvelopeBytes: 1_024,
            maximumArtifactBytes: 1_024,
            maximumArtifactsPerReport: 1
        )
        let queue = CrumbReportQueue(rootURL: root, limits: limits)
        let first = try makeFixture(reportID: "rpt_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", artifactData: Data())
        let second = try makeFixture(reportID: "rpt_DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", artifactData: Data())
        try await queue.enqueue(envelope: first.envelope, artifacts: [])

        await #expect(throws: CrumbReportQueueError.queueFull) {
            try await queue.enqueue(envelope: second.envelope, artifacts: [])
        }
        let reports = try await queue.reports()
        #expect(reports.map(\.reportID) == [first.envelope.reportID])
    }

    @Test
    func startupRemovesOnlyUncommittedTemporaryTransactions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let orphan = root.appendingPathComponent(".tmp-interrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: orphan.appendingPathComponent("envelope.json"))
        let tombstone = root.appendingPathComponent(".delete-accepted", isDirectory: true)
        try FileManager.default.createDirectory(at: tombstone, withIntermediateDirectories: true)
        try Data("accepted".utf8).write(to: tombstone.appendingPathComponent("envelope.json"))

        let queue = CrumbReportQueue(rootURL: root)
        #expect(try await queue.reports().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: tombstone.path))
    }

    @Test(arguments: [false, true])
    func anotherOwnerCannotAdoptIdenticalCommittedBytes(originallyUnowned: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(reportID: "rpt_OwnershipAAAAAAAAAAAAAAAAAAAAAAA")
        let original = CrumbReportQueue(
            rootURL: root,
            ownerFingerprint: originallyUnowned ? nil : String(repeating: "a", count: 64)
        )
        let first = try await original.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        #expect(try await original.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact]) == first)
        let before = try await original.load(reportID: fixture.envelope.reportID)
        let recordURL = root.appendingPathComponent(fixture.envelope.reportID).appendingPathComponent("record.json")
        let beforeRecord = try Data(contentsOf: recordURL)
        let other = CrumbReportQueue(rootURL: root, ownerFingerprint: String(repeating: "b", count: 64))

        await #expect(throws: CrumbReportQueueError.conflictingReport) {
            try await other.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        }

        #expect(try await original.load(reportID: fixture.envelope.reportID) == before)
        #expect(try Data(contentsOf: recordURL) == beforeRecord)
    }

    @Test
    func foreignReportsStillConsumeTheGlobalQueueBudget() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = CrumbQueueLimits(maximumReports: 1)
        let original = CrumbReportQueue(
            rootURL: root, limits: limits, ownerFingerprint: String(repeating: "a", count: 64)
        )
        let fixture = try makeFixture(reportID: "rpt_OriginalAAAAAAAAAAAAAAAAAAAAAAAA")
        try await original.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        let replacement = CrumbReportQueue(
            rootURL: root, limits: limits, ownerFingerprint: String(repeating: "b", count: 64)
        )
        let incoming = try makeFixture(reportID: "rpt_IncomingAAAAAAAAAAAAAAAAAAAAAAAA")

        await #expect(throws: CrumbReportQueueError.queueFull) {
            try await replacement.enqueue(envelope: incoming.envelope, artifacts: [incoming.artifact])
        }
        #expect(try await original.reports().count == 1)
    }

    @Test
    func metadataStoresOnlyTheOpaqueOwnerAndDoesNotChangeTheEnvelope() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(reportID: "rpt_MetadataAAAAAAAAAAAAAAAAAAAAAAAA")
        let key = "synthetic_private_write_key"
        let destination = try #require(URL(string: "https://synthetic-destination.example.invalid/base"))
        let owner = CrumbQueueOwnerFingerprint.make(projectKey: key, ingestionURL: destination)
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: owner)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        let recordURL = root.appendingPathComponent(fixture.envelope.reportID).appendingPathComponent("record.json")
        let data = try Data(contentsOf: recordURL)
        let metadata = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(metadata["schemaVersion"] as? Int == 2)
        #expect(metadata["ownerFingerprint"] as? String == owner)
        #expect(!String(decoding: data, as: UTF8.self).contains(key))
        #expect(!String(decoding: data, as: UTF8.self).contains(destination.absoluteString))
        #expect(try await queue.load(reportID: fixture.envelope.reportID).envelope == fixture.envelope.data)
        #expect(!fixture.envelope.json.contains(owner))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crumb-queue-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFixture(
        reportID: String,
        artifactData: Data = Data("masked-png".utf8)
    ) throws -> (envelope: CrumbSerializedReportEnvelope, artifact: CrumbQueueArtifact) {
        let artifactID = "art_0123456789ABCDEF"
        let digest = SHA256.hash(data: artifactData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = CrumbArtifactManifest(
            id: artifactID,
            kind: "screenshot",
            mimeType: "image/png",
            byteSize: artifactData.count,
            sha256: digest,
            redactionState: "masked",
            uploadID: "upl_0123456789ABCDEF"
        )
        let artifacts: [[String: Any]] = artifactData.isEmpty ? [] : [[
            "id": manifest.id,
            "kind": manifest.kind,
            "mime_type": manifest.mimeType,
            "byte_size": manifest.byteSize,
            "sha256": manifest.sha256,
            "redaction_state": manifest.redactionState,
            "upload_id": manifest.uploadID
        ]]
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": "1.0",
            "report_id": reportID,
            "artifacts": artifacts
        ], options: [.sortedKeys])
        return (
            CrumbSerializedReportEnvelope(
                reportID: reportID,
                submittedAt: Date(timeIntervalSince1970: 1_700_000_000),
                data: data
            ),
            CrumbQueueArtifact(manifest: manifest, data: artifactData)
        )
    }
}
