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
        let queue = CrumbReportQueue(rootURL: root)
        try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
        try await queue.markUploading(reportID: fixture.envelope.reportID)

        let restartedQueue = CrumbReportQueue(rootURL: root)
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
