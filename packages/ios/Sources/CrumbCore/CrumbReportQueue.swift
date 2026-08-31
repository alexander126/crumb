import CryptoKit
import Foundation

package enum CrumbQueuedReportState: String, Codable, Equatable, Sendable {
    case pending
    case uploading
    case failed
}

package struct CrumbQueueLimits: Equatable, Sendable {
    package let maximumReports: Int
    package let maximumTotalBytes: Int
    package let maximumReportBytes: Int
    package let maximumEnvelopeBytes: Int
    package let maximumArtifactBytes: Int
    package let maximumArtifactsPerReport: Int

    package init(
        maximumReports: Int = 50,
        maximumTotalBytes: Int = 134_217_728,
        maximumReportBytes: Int = 27_262_976,
        maximumEnvelopeBytes: Int = 1_048_576,
        maximumArtifactBytes: Int = 26_214_400,
        maximumArtifactsPerReport: Int = 10
    ) {
        self.maximumReports = maximumReports
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumReportBytes = maximumReportBytes
        self.maximumEnvelopeBytes = maximumEnvelopeBytes
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumArtifactsPerReport = maximumArtifactsPerReport
    }
}

package struct CrumbQueueArtifact: Equatable, Sendable {
    package let manifest: CrumbArtifactManifest
    package let data: Data

    package init(manifest: CrumbArtifactManifest, data: Data) {
        self.manifest = manifest
        self.data = data
    }
}

package struct CrumbQueuedReportSummary: Equatable, Sendable {
    package let reportID: String
    package let submittedAt: Date
    package let state: CrumbQueuedReportState
    package let attemptCount: Int
    package let lastError: String?
    package let totalByteSize: Int
    package let artifactCount: Int
}

package struct CrumbQueuedReportPayload: Equatable, Sendable {
    package let summary: CrumbQueuedReportSummary
    package let envelope: Data
    package let artifacts: [CrumbQueueArtifact]
}

package enum CrumbReportQueueError: Error, Equatable {
    case invalidLimits
    case invalidEnvelope
    case invalidArtifact
    case reportTooLarge
    case queueFull
    case conflictingReport
    case reportNotFound
    case corruptQueue
    case storageFailure
}

package actor CrumbReportQueue {
    package static let shared = CrumbReportQueue(rootURL: defaultRootURL())

    private let rootURL: URL
    private let limits: CrumbQueueLimits
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(
        rootURL: URL,
        limits: CrumbQueueLimits = .init(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.limits = limits
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    @discardableResult
    package func enqueue(
        envelope: CrumbSerializedReportEnvelope,
        artifacts: [CrumbQueueArtifact]
    ) throws -> CrumbQueuedReportSummary {
        try validateLimits()
        try prepareRoot()
        try cleanupTemporaryDirectories()
        try validate(envelope: envelope, artifacts: artifacts)

        let totalByteSize = envelope.data.count + artifacts.reduce(0) { $0 + $1.data.count }
        guard totalByteSize <= limits.maximumReportBytes else {
            throw CrumbReportQueueError.reportTooLarge
        }

        let destination = reportURL(envelope.reportID)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try load(reportID: envelope.reportID)
            guard existing.envelope == envelope.data,
                  artifactDataByID(existing.artifacts) == artifactDataByID(artifacts) else {
                throw CrumbReportQueueError.conflictingReport
            }
            return existing.summary
        }

        let existingRecords = try readAllRecords()
        guard existingRecords.count < limits.maximumReports,
              existingRecords.reduce(0, { $0 + $1.totalByteSize }) + totalByteSize
                <= limits.maximumTotalBytes else {
            throw CrumbReportQueueError.queueFull
        }

        let temporary = rootURL.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        do {
            try createProtectedDirectory(temporary)
            let artifactsURL = temporary.appendingPathComponent("artifacts", isDirectory: true)
            if !artifacts.isEmpty { try createProtectedDirectory(artifactsURL) }

            try writeProtected(envelope.data, to: temporary.appendingPathComponent("envelope.json"))
            for artifact in artifacts {
                try writeProtected(
                    artifact.data,
                    to: artifactsURL.appendingPathComponent(fileName(for: artifact.manifest.id))
                )
            }

            let record = StoredRecord(
                schemaVersion: 1,
                reportID: envelope.reportID,
                submittedAt: envelope.submittedAt,
                state: .pending,
                attemptCount: 0,
                lastError: nil,
                totalByteSize: totalByteSize,
                envelopeByteSize: envelope.data.count,
                envelopeSHA256: sha256(envelope.data),
                artifacts: artifacts.map(StoredArtifact.init)
            )
            try writeRecord(record, inside: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            try applyStorageAttributes(to: destination)
            return summary(record)
        } catch let error as CrumbReportQueueError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CrumbReportQueueError.storageFailure
        }
    }

    package func reports() throws -> [CrumbQueuedReportSummary] {
        try validateLimits()
        try prepareRoot()
        try cleanupTemporaryDirectories()
        return try readAllRecords()
            .sorted { $0.submittedAt < $1.submittedAt }
            .map(summary)
    }

    package func load(reportID: String) throws -> CrumbQueuedReportPayload {
        guard validReportID(reportID) else {
            throw CrumbReportQueueError.reportNotFound
        }
        try prepareRoot()
        let directory = reportURL(reportID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CrumbReportQueueError.reportNotFound
        }
        let record = try readRecord(inside: directory)
        let envelope = try readData(directory.appendingPathComponent("envelope.json"))
        guard envelope.count == record.envelopeByteSize,
              sha256(envelope) == record.envelopeSHA256 else {
            throw CrumbReportQueueError.corruptQueue
        }

        let artifacts = try record.artifacts.map { stored -> CrumbQueueArtifact in
            let data = try readData(
                directory
                    .appendingPathComponent("artifacts", isDirectory: true)
                    .appendingPathComponent(stored.fileName)
            )
            guard data.count == stored.byteSize, sha256(data) == stored.sha256 else {
                throw CrumbReportQueueError.corruptQueue
            }
            return CrumbQueueArtifact(manifest: stored.manifest, data: data)
        }
        guard envelope.count + artifacts.reduce(0, { $0 + $1.data.count }) == record.totalByteSize else {
            throw CrumbReportQueueError.corruptQueue
        }
        return CrumbQueuedReportPayload(
            summary: summary(record),
            envelope: envelope,
            artifacts: artifacts
        )
    }

    package func markUploading(reportID: String) throws {
        try updateRecord(reportID: reportID) { record in
            record.state = .uploading
            record.attemptCount += 1
            record.lastError = nil
        }
    }

    package func markFailed(reportID: String, reason: String) throws {
        try updateRecord(reportID: reportID) { record in
            record.state = .failed
            record.lastError = sanitizedReason(reason)
        }
    }

    package func markPending(reportID: String) throws {
        try updateRecord(reportID: reportID) { record in
            record.state = .pending
            record.lastError = nil
        }
    }

    /// Removes a report only after the server has durably accepted it.
    package func remove(reportID: String) throws {
        guard validReportID(reportID) else {
            throw CrumbReportQueueError.reportNotFound
        }
        let directory = reportURL(reportID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CrumbReportQueueError.reportNotFound
        }
        let tombstone = rootURL.appendingPathComponent(
            ".delete-\(reportID)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: directory, to: tombstone)
            // The atomic rename is the durable removal. Byte cleanup may finish later.
            try? fileManager.removeItem(at: tombstone)
        } catch {
            throw CrumbReportQueueError.storageFailure
        }
    }

    /// Upload work interrupted by process termination becomes retryable on the next launch.
    package func recoverInterruptedUploads() throws {
        try prepareRoot()
        try cleanupTemporaryDirectories()
        for record in try readAllRecords() where record.state == .uploading {
            try updateRecord(reportID: record.reportID) { value in
                value.state = .pending
                value.lastError = nil
            }
        }
    }

    private func validateLimits() throws {
        guard limits.maximumReports > 0,
              limits.maximumTotalBytes > 0,
              limits.maximumReportBytes > 0,
              limits.maximumEnvelopeBytes > 0,
              limits.maximumArtifactBytes > 0,
              limits.maximumArtifactsPerReport >= 0,
              limits.maximumReportBytes <= limits.maximumTotalBytes else {
            throw CrumbReportQueueError.invalidLimits
        }
    }

    private func validate(
        envelope: CrumbSerializedReportEnvelope,
        artifacts: [CrumbQueueArtifact]
    ) throws {
        guard envelope.data.count <= limits.maximumEnvelopeBytes,
              artifacts.count <= limits.maximumArtifactsPerReport,
              Set(artifacts.map(\.manifest.id)).count == artifacts.count,
              validReportID(envelope.reportID),
              let root = try? JSONSerialization.jsonObject(with: envelope.data) as? [String: Any],
              root["report_id"] as? String == envelope.reportID,
              let manifests = root["artifacts"] as? [[String: Any]] else {
            throw CrumbReportQueueError.invalidEnvelope
        }

        let storedByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.manifest.id, $0) })
        guard Set(manifests.compactMap { $0["id"] as? String }) == Set(storedByID.keys),
              manifests.count == artifacts.count else {
            throw CrumbReportQueueError.invalidEnvelope
        }

        for manifest in manifests {
            guard let id = manifest["id"] as? String,
                  let artifact = storedByID[id],
                  validArtifactID(id),
                  artifact.data.count <= limits.maximumArtifactBytes,
                  artifact.data.count == artifact.manifest.byteSize,
                  sha256(artifact.data) == artifact.manifest.sha256,
                  manifest["byte_size"] as? Int == artifact.manifest.byteSize,
                  manifest["sha256"] as? String == artifact.manifest.sha256,
                  manifest["mime_type"] as? String == artifact.manifest.mimeType else {
                throw CrumbReportQueueError.invalidArtifact
            }
        }
    }

    private func prepareRoot() throws {
        do {
            if !fileManager.fileExists(atPath: rootURL.path) {
                try createProtectedDirectory(rootURL)
            }
            try applyStorageAttributes(to: rootURL)
        } catch {
            throw CrumbReportQueueError.storageFailure
        }
    }

    private func cleanupTemporaryDirectories() throws {
        do {
            for url in try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: []
            ) where url.lastPathComponent.hasPrefix(".tmp-")
                || url.lastPathComponent.hasPrefix(".delete-") {
                if url.lastPathComponent.hasPrefix(".delete-") {
                    try? fileManager.removeItem(at: url)
                } else {
                    try fileManager.removeItem(at: url)
                }
            }
        } catch {
            throw CrumbReportQueueError.storageFailure
        }
    }

    private func readAllRecords() throws -> [StoredRecord] {
        do {
            let directories = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return try directories.compactMap { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { return nil }
                return try readRecord(inside: url)
            }
        } catch let error as CrumbReportQueueError {
            throw error
        } catch {
            throw CrumbReportQueueError.corruptQueue
        }
    }

    private func readRecord(inside directory: URL) throws -> StoredRecord {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("record.json"))
            let record = try decoder.decode(StoredRecord.self, from: data)
            guard record.schemaVersion == 1,
                  record.reportID == directory.lastPathComponent,
                  record.totalByteSize >= 0,
                  record.envelopeByteSize >= 0,
                  record.attemptCount >= 0,
                  record.artifacts.allSatisfy({
                      validArtifactID($0.id)
                          && $0.fileName == fileName(for: $0.id)
                          && $0.byteSize >= 0
                  }) else {
                throw CrumbReportQueueError.corruptQueue
            }
            return record
        } catch let error as CrumbReportQueueError {
            throw error
        } catch {
            throw CrumbReportQueueError.corruptQueue
        }
    }

    private func writeRecord(_ record: StoredRecord, inside directory: URL) throws {
        do {
            try writeProtected(
                encoder.encode(record),
                to: directory.appendingPathComponent("record.json")
            )
        } catch {
            throw CrumbReportQueueError.storageFailure
        }
    }

    private func updateRecord(
        reportID: String,
        mutation: (inout StoredRecord) -> Void
    ) throws {
        guard validReportID(reportID) else {
            throw CrumbReportQueueError.reportNotFound
        }
        let directory = reportURL(reportID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CrumbReportQueueError.reportNotFound
        }
        var record = try readRecord(inside: directory)
        mutation(&record)
        try writeRecord(record, inside: directory)
    }

    private func createProtectedDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try applyStorageAttributes(to: url)
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try applyStorageAttributes(to: url)
    }

    private func applyStorageAttributes(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func readData(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CrumbReportQueueError.corruptQueue
        }
    }

    private func reportURL(_ reportID: String) -> URL {
        rootURL.appendingPathComponent(reportID, isDirectory: true)
    }

    private func fileName(for artifactID: String) -> String { "\(artifactID).blob" }

    private func summary(_ record: StoredRecord) -> CrumbQueuedReportSummary {
        CrumbQueuedReportSummary(
            reportID: record.reportID,
            submittedAt: record.submittedAt,
            state: record.state,
            attemptCount: record.attemptCount,
            lastError: record.lastError,
            totalByteSize: record.totalByteSize,
            artifactCount: record.artifacts.count
        )
    }

    private func artifactDataByID(_ artifacts: [CrumbQueueArtifact]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: artifacts.map { ($0.manifest.id, $0.data) })
    }

    private func validArtifactID(_ value: String) -> Bool {
        value.range(of: "^art_[A-Za-z0-9_-]{12,80}$", options: .regularExpression) != nil
    }

    private func validReportID(_ value: String) -> Bool {
        value.range(of: "^rpt_[A-Za-z0-9_-]{16,80}$", options: .regularExpression) != nil
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sanitizedReason(_ value: String) -> String {
        String(
            value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .prefix(512)
        )
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("dev.crumb", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
    }

    private struct StoredArtifact: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let mimeType: String
        let byteSize: Int
        let sha256: String
        let redactionState: String
        let uploadID: String
        let fileName: String

        init(_ artifact: CrumbQueueArtifact) {
            let manifest = artifact.manifest
            id = manifest.id
            kind = manifest.kind
            mimeType = manifest.mimeType
            byteSize = manifest.byteSize
            sha256 = manifest.sha256
            redactionState = manifest.redactionState
            uploadID = manifest.uploadID
            fileName = "\(manifest.id).blob"
        }

        var manifest: CrumbArtifactManifest {
            CrumbArtifactManifest(
                id: id,
                kind: kind,
                mimeType: mimeType,
                byteSize: byteSize,
                sha256: sha256,
                redactionState: redactionState,
                uploadID: uploadID
            )
        }
    }

    private struct StoredRecord: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let reportID: String
        let submittedAt: Date
        var state: CrumbQueuedReportState
        var attemptCount: Int
        var lastError: String?
        let totalByteSize: Int
        let envelopeByteSize: Int
        let envelopeSHA256: String
        let artifacts: [StoredArtifact]
    }
}
