import CryptoKit
import Foundation
import Testing
@testable import CrumbCore

/// Real queues on temporary roots with explicit owner fingerprints. Every
/// corruption here is applied to committed bytes on disk, the way a damaged
/// device would present them.
@Suite(.serialized)
struct CrumbQueueMetadataIsolationTests {
    private static let healthyID = "rpt_HealthyAAAAAAAAAAAAAAAAAAAAAAAA"
    private static let damagedID = "rpt_DamagedBBBBBBBBBBBBBBBBBBBBBBBB"
    private static let arrivingID = "rpt_ArrivingCCCCCCCCCCCCCCCCCCCCCC"
    private static let owner = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /// The defect this fixes: one damaged metadata record aborted the scan that
    /// serves listing, recovery and admission, so healthy siblings became
    /// invisible and new reports could not be committed.
    @Test
    func aDamagedRecordDoesNotHideItsHealthySiblings() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try await enqueue(Self.damagedID, into: queue)
        try write(Data("{ not json".utf8), toRecordOf: Self.damagedID, in: root)

        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        let listed = try await restarted.reports()
        try await restarted.recoverInterruptedUploads(ownedBy: Self.owner)
        let owned = try await restarted.reports(ownedBy: Self.owner)
        let payload = try await restarted.load(reportID: Self.healthyID)
        let admitted = try await enqueue(Self.arrivingID, into: restarted)

        #expect(listed.map(\.reportID) == [Self.healthyID])
        #expect(owned.map(\.reportID) == [Self.healthyID])
        #expect(payload.summary.reportID == Self.healthyID)
        #expect(admitted.reportID == Self.arrivingID)
    }

    @Test
    func anUploadingSiblingRecoversExactlyOnceAcrossTwoRestarts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try await enqueue(Self.damagedID, into: queue)
        try await queue.markUploading(reportID: Self.healthyID)
        try write(Data("{ not json".utf8), toRecordOf: Self.damagedID, in: root)
        let damagedBytes = try recordBytes(of: Self.damagedID, in: root)

        let first = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await first.recoverInterruptedUploads(ownedBy: Self.owner)
        let afterFirst = try await first.load(reportID: Self.healthyID).summary
        let second = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await second.recoverInterruptedUploads(ownedBy: Self.owner)
        let afterSecond = try await second.load(reportID: Self.healthyID).summary

        #expect(afterFirst.state == .pending)
        #expect(afterSecond.state == .pending)
        #expect(afterFirst.attemptCount == afterSecond.attemptCount)
        // The damaged entry is untouched: not repaired, not renamed, not deleted.
        #expect(try recordBytes(of: Self.damagedID, in: root) == damagedBytes)
        #expect(FileManager.default.fileExists(atPath: directory(of: Self.damagedID, in: root).path))
    }

    @Test(arguments: [
        "{ not json",
        "{}",
        "[]",
        #"{"schemaVersion":2}"#,
        #"{"schemaVersion":2,"reportID":"rpt_SomethingElseAAAAAAAAAAAAAAA"}"#,
        #"{"schemaVersion":2,"reportID":"__","submittedAt":0,"state":"pending","attemptCount":-1,"totalByteSize":1,"envelopeByteSize":1,"envelopeSHA256":"x","artifacts":[]}"#,
        #"{"schemaVersion":2,"reportID":"rpt_DamagedBBBBBBBBBBBBBBBBBBBBBBBB","submittedAt":0,"state":"teleporting","attemptCount":0,"totalByteSize":1,"envelopeByteSize":1,"envelopeSHA256":"x","artifacts":[]}"#
    ])
    func rejectedMetadataIsolatesOnlyItsOwnEntry(metadata: String) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try await enqueue(Self.damagedID, into: queue)
        try write(Data(metadata.utf8), toRecordOf: Self.damagedID, in: root)

        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        let listed = try await restarted.reports()

        #expect(listed.map(\.reportID) == [Self.healthyID])
        // Direct load and same-ID admission stay strict about it.
        await #expect(throws: CrumbReportQueueError.self) {
            _ = try await restarted.load(reportID: Self.damagedID)
        }
        await #expect(throws: CrumbReportQueueError.self) {
            _ = try await self.enqueue(Self.damagedID, into: restarted)
        }
    }

    @Test
    func positivelyMissingMetadataIsolatesWithoutForgettingTheDirectory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try await enqueue(Self.damagedID, into: queue)
        try FileManager.default.removeItem(
            at: directory(of: Self.damagedID, in: root).appendingPathComponent("record.json")
        )

        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        let listed = try await restarted.reports()

        #expect(listed.map(\.reportID) == [Self.healthyID])
        #expect(FileManager.default.fileExists(atPath: directory(of: Self.damagedID, in: root).path))
        // The ID stays reserved even though nothing can be read from it.
        await #expect(throws: CrumbReportQueueError.self) {
            _ = try await self.enqueue(Self.damagedID, into: restarted)
        }
    }

    @Test(arguments: [
        #"{"schemaVersion":3,"reportID":"rpt_DamagedBBBBBBBBBBBBBBBBBBBBBBBB","submittedAt":0,"state":"pending","attemptCount":0,"totalByteSize":1,"envelopeByteSize":1,"envelopeSHA256":"x","artifacts":[]}"#,
        #"{"schemaVersion":3,"somethingNew":true}"#,
        #"{"schemaVersion":99}"#,
        #"{"schemaVersion":0}"#
    ])
    func anUnsupportedVersionFailsTheWholeOperation(metadata: String) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try await enqueue(Self.damagedID, into: queue)
        try write(Data(metadata.utf8), toRecordOf: Self.damagedID, in: root)

        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)

        // Never skipped as ordinary corruption, and never adopted.
        await #expect(throws: CrumbReportQueueError.self) {
            _ = try await restarted.reports()
        }
    }

    @Test
    func aMetadataIOFailureIsRetryableRatherThanQuarantined() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        let recordURL = directory(of: Self.healthyID, in: root)
            .appendingPathComponent("record.json")
        let saved = try Data(contentsOf: recordURL)
        // A directory where the metadata file belongs fails the read for every
        // uid, unlike a permission bit.
        try FileManager.default.removeItem(at: recordURL)
        try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: false)

        let blocked = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        await #expect(throws: CrumbReportQueueError.self) {
            _ = try await blocked.reports()
        }

        // Restored I/O makes the original record usable again: it was never
        // quarantined.
        try FileManager.default.removeItem(at: recordURL)
        try saved.write(to: recordURL)
        let restored = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        let listed = try await restored.reports()

        #expect(listed.map(\.reportID) == [Self.healthyID])
    }

    @Test
    func admissionCountsOpaqueEntriesAgainstTheReportLimit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = CrumbQueueLimits(maximumReports: 2)
        let queue = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try await enqueue(Self.damagedID, into: queue)
        try write(Data("{ not json".utf8), toRecordOf: Self.damagedID, in: root)

        let restarted = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        let listed = try await restarted.reports()

        // One record lists, but two directories are retained, so the queue is
        // full. Isolation must not hand out a slot the queue cannot honor.
        #expect(listed.count == 1)
        await #expect(throws: CrumbReportQueueError.queueFull) {
            _ = try await self.enqueue(Self.arrivingID, into: restarted)
        }
    }

    /// The discriminator between counting what metadata promises and counting
    /// what is on disk: here the metadata understates the payload, and the
    /// record stays otherwise valid so it still lists.
    @Test
    func admissionCountsRetainedBytesRatherThanMetadataPromises() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(reportID: Self.healthyID)
        let payloadBytes = fixture.envelope.data.count + fixture.artifact.data.count
        let limits = CrumbQueueLimits(
            maximumReports: 10,
            maximumTotalBytes: payloadBytes + 8,
            maximumReportBytes: payloadBytes
        )
        let queue = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try understateTotalByteSize(of: Self.healthyID, in: root)

        let restarted = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        let listed = try await restarted.reports()

        #expect(listed.map(\.reportID) == [Self.healthyID])
        // Metadata claims zero bytes; the envelope and artifact on disk say
        // otherwise, and they are what the quota is measured against.
        await #expect(throws: CrumbReportQueueError.queueFull) {
            _ = try await self.enqueue(Self.arrivingID, into: restarted)
        }
    }

    @Test
    func anUnreferencedArtifactBlobStillCountsAsRetainedPayload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(reportID: Self.healthyID)
        let payloadBytes = fixture.envelope.data.count + fixture.artifact.data.count
        // Room for both reports but not for the stray blob, so the blob decides
        // the outcome: metadata does not mention it at all.
        let limits = CrumbQueueLimits(
            maximumReports: 10,
            maximumTotalBytes: 2 * payloadBytes + 32,
            maximumReportBytes: payloadBytes
        )
        let queue = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try Data(repeating: 0x5A, count: 64).write(
            to: directory(of: Self.healthyID, in: root)
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent("art_UnreferencedAAAA.bin")
        )

        let restarted = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        await #expect(throws: CrumbReportQueueError.queueFull) {
            _ = try await self.enqueue(Self.arrivingID, into: restarted)
        }
    }

    @Test
    func aSymlinkInAReportDirectoryFailsAdmissionClosed() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let queue = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        try await enqueue(Self.healthyID, into: queue)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("target.bin")
        try Data(repeating: 0x5A, count: 32).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory(of: Self.healthyID, in: root)
                .appendingPathComponent("artifacts", isDirectory: true)
                .appendingPathComponent("art_LinkedAAAAAAAAA.bin"),
            withDestinationURL: target
        )

        let restarted = CrumbReportQueue(rootURL: root, ownerFingerprint: Self.owner)
        await #expect(throws: CrumbReportQueueError.self) {
            _ = try await self.enqueue(Self.arrivingID, into: restarted)
        }
        // Nothing outside the queue was read through, and nothing was removed.
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func aCommittedDirectoryWithNoPayloadCountsZeroBytesAndKeepsItsSlot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limits = CrumbQueueLimits(maximumReports: 3)
        let queue = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        try await enqueue(Self.damagedID, into: queue)
        let damaged = directory(of: Self.damagedID, in: root)
        try FileManager.default.removeItem(at: damaged.appendingPathComponent("envelope.json"))
        try FileManager.default.removeItem(
            at: damaged.appendingPathComponent("artifacts", isDirectory: true)
        )
        try write(Data("{ not json".utf8), toRecordOf: Self.damagedID, in: root)

        let restarted = CrumbReportQueue(rootURL: root, limits: limits, ownerFingerprint: Self.owner)
        // Zero payload bytes, so a new report of its own size still fits...
        let admitted = try await enqueue(Self.arrivingID, into: restarted)
        // ...while the directory still consumes a slot and reserves its ID.
        #expect(admitted.reportID == Self.arrivingID)
        #expect(FileManager.default.fileExists(atPath: damaged.path))
        await #expect(throws: CrumbReportQueueError.self) {
            _ = try await self.enqueue(Self.damagedID, into: restarted)
        }
    }

    // MARK: - Fixtures

    @discardableResult
    private func enqueue(
        _ reportID: String,
        into queue: CrumbReportQueue
    ) async throws -> CrumbQueuedReportSummary {
        let fixture = try makeFixture(reportID: reportID)
        return try await queue.enqueue(envelope: fixture.envelope, artifacts: [fixture.artifact])
    }

    private func directory(of reportID: String, in root: URL) -> URL {
        root.appendingPathComponent(reportID, isDirectory: true)
    }

    private func write(_ data: Data, toRecordOf reportID: String, in root: URL) throws {
        try data.write(to: directory(of: reportID, in: root).appendingPathComponent("record.json"))
    }

    /// Rewrites the record with a zero payload claim, leaving it valid in every
    /// other respect.
    private func understateTotalByteSize(of reportID: String, in root: URL) throws {
        let url = directory(of: reportID, in: root).appendingPathComponent("record.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        )
        object["totalByteSize"] = 0
        object["envelopeByteSize"] = 0
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func recordBytes(of reportID: String, in root: URL) throws -> Data {
        try Data(
            contentsOf: directory(of: reportID, in: root).appendingPathComponent("record.json")
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("crumb-isolation-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeFixture(
        reportID: String,
        artifactData: Data = Data("masked-png".utf8)
    ) throws -> (envelope: CrumbSerializedReportEnvelope, artifact: CrumbQueueArtifact) {
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
        let data = try JSONSerialization.data(
            withJSONObject: [
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
            ],
            options: [.sortedKeys]
        )
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
