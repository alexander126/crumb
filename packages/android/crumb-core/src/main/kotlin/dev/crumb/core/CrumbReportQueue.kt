package dev.crumb.core

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Base64
import java.util.Properties
import java.util.UUID

enum class CrumbQueuedReportState { PENDING, UPLOADING, FAILED }

data class CrumbQueueLimits(
    val maximumReports: Int = 50,
    val maximumTotalBytes: Long = 134_217_728,
    val maximumReportBytes: Long = 27_262_976,
    val maximumEnvelopeBytes: Long = 1_048_576,
    val maximumArtifactBytes: Long = 26_214_400,
    val maximumArtifactsPerReport: Int = 10,
)

data class CrumbQueueArtifact(
    val manifest: CrumbArtifactManifest,
    val bytes: ByteArray,
)

data class CrumbQueuedReportSummary(
    val reportId: String,
    val submittedAtMillis: Long,
    val state: CrumbQueuedReportState,
    val attemptCount: Int,
    val lastError: String?,
    val totalByteSize: Long,
    val artifactCount: Int,
)

data class CrumbQueuedReportPayload(
    val summary: CrumbQueuedReportSummary,
    val envelope: ByteArray,
    val artifacts: List<CrumbQueueArtifact>,
)

sealed class CrumbReportQueueException(message: String) : IllegalStateException(message) {
    class InvalidLimits : CrumbReportQueueException("queue limits are invalid")
    class InvalidEnvelope : CrumbReportQueueException("report envelope is invalid")
    class InvalidArtifact : CrumbReportQueueException("report artifact is invalid")
    class ReportTooLarge : CrumbReportQueueException("report exceeds the local queue limit")
    class QueueFull : CrumbReportQueueException("local report queue is full")
    class ConflictingReport : CrumbReportQueueException("report id already has different content")
    class ReportNotFound : CrumbReportQueueException("queued report does not exist")
    class CorruptQueue : CrumbReportQueueException("local report queue is corrupt")
    class StorageFailure : CrumbReportQueueException("local report queue could not be written")
    class UnsupportedProcess :
        CrumbReportQueueException("local report queue is supported only in the application's main process")
}

class CrumbReportQueue internal constructor(
    private val root: File,
    private val limits: CrumbQueueLimits = CrumbQueueLimits(),
) {
    private var fixedOwner: String? = null
    private var usesConfiguredOwner = false

    internal constructor(
        root: File,
        owner: String,
        limits: CrumbQueueLimits = CrumbQueueLimits(),
    ) : this(root, limits) {
        fixedOwner = owner
    }

    private fun resolveOwner(): String? = if (usesConfiguredOwner) Crumb.queueOwner() else fixedOwner

    @Synchronized
    fun enqueue(
        envelope: CrumbSerializedReportEnvelope,
        artifacts: List<CrumbQueueArtifact>,
    ): CrumbQueuedReportSummary {
        val owner = resolveOwner()
        validateLimits()
        prepareRoot()
        cleanupTemporaryTransactions()
        validate(envelope, artifacts)

        val envelopeBytes = envelope.json.toByteArray(Charsets.UTF_8)
        val totalByteSize = envelopeBytes.size.toLong() + artifacts.sumOf { it.bytes.size.toLong() }
        if (totalByteSize > limits.maximumReportBytes) {
            throw CrumbReportQueueException.ReportTooLarge()
        }

        val destination = reportDirectory(envelope.reportId)
        if (destination.exists()) {
            if (readRecord(destination).ownerFingerprint != owner) {
                throw CrumbReportQueueException.ConflictingReport()
            }
            val existing = load(envelope.reportId)
            if (!existing.envelope.contentEquals(envelopeBytes) ||
                !sameArtifactBytes(existing.artifacts, artifacts)
            ) {
                throw CrumbReportQueueException.ConflictingReport()
            }
            return existing.summary
        }

        // Quotas are measured against what is retained, not against what the
        // retained metadata claims: an entry whose metadata cannot be read must
        // still occupy its slot and its bytes.
        val (reportCount, payloadByteSize) = retainedOccupancy()
        if (
            reportCount >= limits.maximumReports ||
            checkedPlus(payloadByteSize, totalByteSize) > limits.maximumTotalBytes
        ) {
            throw CrumbReportQueueException.QueueFull()
        }

        val temporary = File(root, ".tmp-${UUID.randomUUID()}")
        try {
            createDirectory(temporary)
            val artifactDirectory = File(temporary, ARTIFACT_DIRECTORY)
            if (artifacts.isNotEmpty()) createDirectory(artifactDirectory)

            writeDurably(File(temporary, ENVELOPE_FILE), envelopeBytes)
            val manifests = ArrayList<CrumbArtifactManifest>(artifacts.size)
            for (artifact in artifacts) {
                writeDurably(File(artifactDirectory, fileName(artifact.manifest.id)), artifact.bytes)
                manifests.add(artifact.manifest)
            }
            val record = StoredRecord(
                reportId = envelope.reportId,
                submittedAtMillis = envelope.submittedAtMillis,
                state = CrumbQueuedReportState.PENDING,
                attemptCount = 0,
                lastError = null,
                totalByteSize = totalByteSize,
                envelopeByteSize = envelopeBytes.size.toLong(),
                envelopeSha256 = sha256(envelopeBytes),
                artifacts = manifests,
                schemaVersion = 2,
                ownerFingerprint = owner,
            )
            writeRecord(temporary, record)
            atomicMove(temporary, destination)
            return record.summary()
        } catch (error: CrumbReportQueueException) {
            deleteWithoutFollowingLinks(temporary)
            throw error
        } catch (_: Exception) {
            deleteWithoutFollowingLinks(temporary)
            throw CrumbReportQueueException.StorageFailure()
        }
    }

    @Synchronized
    fun reports(): List<CrumbQueuedReportSummary> = reportSummaries(null)

    @Synchronized
    internal fun ownedReports(owner: String): List<CrumbQueuedReportSummary> =
        reportSummaries(owner)

    private fun reportSummaries(ownerFingerprint: String?): List<CrumbQueuedReportSummary> {
        validateLimits()
        prepareRoot()
        cleanupTemporaryTransactions()
        val records = readAllRecords().toMutableList()
        records.sortWith(java.util.Comparator.comparingLong<StoredRecord> { it.submittedAtMillis })
        val summaries = ArrayList<CrumbQueuedReportSummary>(records.size)
        for (record in records) {
            if (ownerFingerprint == null || record.ownerFingerprint == ownerFingerprint) {
                summaries.add(record.summary())
            }
        }
        return summaries
    }

    @Synchronized
    fun load(reportId: String): CrumbQueuedReportPayload {
        if (!validReportId(reportId)) throw CrumbReportQueueException.ReportNotFound()
        prepareRoot()
        val directory = reportDirectory(reportId)
        if (!directory.isDirectory) throw CrumbReportQueueException.ReportNotFound()
        val record = readRecord(directory)
        val envelope = readData(File(directory, ENVELOPE_FILE))
        if (
            envelope.size.toLong() != record.envelopeByteSize ||
            sha256(envelope) != record.envelopeSha256
        ) {
            throw CrumbReportQueueException.CorruptQueue()
        }
        val artifacts = ArrayList<CrumbQueueArtifact>(record.artifacts.size)
        var payloadBytes = envelope.size.toLong()
        for (manifest in record.artifacts) {
            val bytes = readData(File(File(directory, ARTIFACT_DIRECTORY), fileName(manifest.id)))
            if (bytes.size.toLong() != manifest.byteSize || sha256(bytes) != manifest.sha256) {
                throw CrumbReportQueueException.CorruptQueue()
            }
            artifacts.add(CrumbQueueArtifact(manifest, bytes))
            payloadBytes += bytes.size.toLong()
        }
        if (payloadBytes != record.totalByteSize) {
            throw CrumbReportQueueException.CorruptQueue()
        }
        return CrumbQueuedReportPayload(record.summary(), envelope, artifacts)
    }

    @Synchronized
    fun markUploading(reportId: String) = updateRecord(reportId) { record ->
        record.copy(
            state = CrumbQueuedReportState.UPLOADING,
            attemptCount = record.attemptCount + 1,
            lastError = null,
        )
    }

    @Synchronized
    fun markFailed(reportId: String, reason: String) = updateRecord(reportId) { record ->
        record.copy(
            state = CrumbQueuedReportState.FAILED,
            lastError = sanitizeReason(reason),
        )
    }

    @Synchronized
    fun markPending(reportId: String) = updateRecord(reportId) { record ->
        record.copy(state = CrumbQueuedReportState.PENDING, lastError = null)
    }

    /** Removes a report only after the server has durably accepted it. */
    @Synchronized
    fun remove(reportId: String) {
        if (!validReportId(reportId)) throw CrumbReportQueueException.ReportNotFound()
        val directory = reportDirectory(reportId)
        if (!directory.isDirectory) throw CrumbReportQueueException.ReportNotFound()
        val tombstone = File(root, "$DELETE_PREFIX$reportId-${UUID.randomUUID()}")
        atomicMove(directory, tombstone)
        // The atomic rename is the durable removal. Byte cleanup may finish later.
        deleteWithoutFollowingLinks(tombstone)
    }

    /** Upload work interrupted by process termination becomes retryable on the next launch. */
    @Synchronized
    fun recoverInterruptedUploads() {
        val owner = resolveOwner() ?: return
        recoverInterruptedUploads(owner)
    }

    @Synchronized
    internal fun recoverInterruptedUploads(owner: String) {
        prepareRoot()
        cleanupTemporaryTransactions()
        for (record in readAllRecords()) {
            if (record.ownerFingerprint == owner && record.state == CrumbQueuedReportState.UPLOADING) {
                updateRecord(record.reportId) { it.copy(state = CrumbQueuedReportState.PENDING, lastError = null) }
            }
        }
    }

    private fun validateLimits() {
        if (
            limits.maximumReports <= 0 || limits.maximumTotalBytes <= 0 ||
            limits.maximumReportBytes <= 0 || limits.maximumEnvelopeBytes <= 0 ||
            limits.maximumArtifactBytes <= 0 || limits.maximumArtifactsPerReport < 0 ||
            limits.maximumReportBytes > limits.maximumTotalBytes
        ) {
            throw CrumbReportQueueException.InvalidLimits()
        }
    }

    private fun validate(
        envelope: CrumbSerializedReportEnvelope,
        artifacts: List<CrumbQueueArtifact>,
    ) {
        val envelopeBytes = envelope.json.toByteArray(Charsets.UTF_8)
        if (
            envelopeBytes.size > limits.maximumEnvelopeBytes ||
            artifacts.size > limits.maximumArtifactsPerReport ||
            !validReportId(envelope.reportId) ||
            !envelope.json.contains("\"report_id\":\"${envelope.reportId}\"")
        ) {
            throw CrumbReportQueueException.InvalidEnvelope()
        }
        val artifactIds = HashSet<String>()
        for (artifact in artifacts) artifactIds.add(artifact.manifest.id)
        if (artifactIds.size != artifacts.size) throw CrumbReportQueueException.InvalidEnvelope()
        val envelopeArtifactIds = HashSet<String>()
        var envelopeArtifactCount = 0
        for (match in ARTIFACT_ID_PATTERN.findAll(envelope.json)) {
            envelopeArtifactIds.add(match.groupValues[1])
            envelopeArtifactCount += 1
        }
        if (envelopeArtifactIds != artifactIds || envelopeArtifactCount != artifacts.size
        ) {
            throw CrumbReportQueueException.InvalidEnvelope()
        }
        artifacts.forEach { artifact ->
            val manifest = artifact.manifest
            if (
                !validArtifactId(manifest.id) ||
                artifact.bytes.size > limits.maximumArtifactBytes ||
                artifact.bytes.size.toLong() != manifest.byteSize ||
                sha256(artifact.bytes) != manifest.sha256 ||
                !envelope.json.contains("\"byte_size\":${manifest.byteSize}") ||
                !envelope.json.contains("\"sha256\":\"${manifest.sha256}\"") ||
                !envelope.json.contains("\"mime_type\":\"${manifest.mimeType}\"")
            ) {
                throw CrumbReportQueueException.InvalidArtifact()
            }
        }
    }

    private fun prepareRoot() {
        if (!root.exists()) createDirectory(root)
        if (!root.isDirectory) throw CrumbReportQueueException.StorageFailure()
    }

    private fun cleanupTemporaryTransactions() {
        for (file in root.listFiles().orEmpty()) {
            if (file.name.startsWith(TEMPORARY_PREFIX) || file.name.startsWith(DELETE_PREFIX)) {
                deleteWithoutFollowingLinks(file)
            }
        }
    }

    /**
     * Deletes queue bytes without following symbolic links.
     *
     * Kotlin's File.deleteRecursively walks with FileTreeWalk, which follows
     * links to directories and offers no no-follow option, so a link planted in
     * a staging or tombstone tree deleted its target's contents outside the
     * queue root. Here a link is never listed, and File.delete unlinks the link
     * itself. Best effort, like the deletion it replaces.
     */
    private fun deleteWithoutFollowingLinks(file: File) {
        if (!Files.isSymbolicLink(file.toPath())) {
            file.listFiles()?.forEach(::deleteWithoutFollowingLinks)
        }
        file.delete()
    }

    /**
     * Every committed report directory. Staging and tombstone entries are
     * excluded by name; a symbolic link is not a committed report and fails
     * closed rather than being followed.
     */
    private fun committedDirectories(): List<File> {
        val entries = root.listFiles() ?: throw CrumbReportQueueException.StorageFailure()
        return entries.filter { entry ->
            if (entry.name.startsWith(TEMPORARY_PREFIX) || entry.name.startsWith(DELETE_PREFIX)) {
                false
            } else {
                attributes(entry).isDirectory
            }
        }
    }

    /**
     * Valid records only. An entry whose metadata is confirmed invalid is
     * isolated: skipped here, never mutated, its directory and report ID still
     * reserved, and its healthy siblings still list, recover and upload.
     */
    private fun readAllRecords(): List<StoredRecord> {
        val records = ArrayList<StoredRecord>()
        for (directory in committedDirectories()) {
            readRecordOrNull(directory)?.let(records::add)
        }
        return records
    }

    /**
     * Strict read for callers that name one report: direct load and same-ID
     * admission must refuse invalid metadata rather than skip it.
     */
    private fun readRecord(directory: File): StoredRecord =
        readRecordOrNull(directory) ?: throw CrumbReportQueueException.CorruptQueue()

    /**
     * What the queue is holding, independent of what any metadata promises, so
     * an entry with unreadable metadata still consumes its slot and its real
     * bytes still count.
     */
    private fun retainedOccupancy(): Pair<Int, Long> {
        val directories = committedDirectories()
        var payloadBytes = 0L
        for (directory in directories) {
            payloadBytes = checkedPlus(payloadBytes, retainedPayloadBytes(directory))
        }
        return directories.size to payloadBytes
    }

    /**
     * Envelope plus every retained artifact file, including blobs no manifest
     * references. Metadata is excluded from payload budgets. A symbolic link, a
     * non-regular file, a failed stat or an entry that disappears mid-scan fails
     * admission closed.
     */
    private fun retainedPayloadBytes(directory: File): Long {
        var total = fileByteSize(File(directory, ENVELOPE_FILE))
        val artifacts = File(directory, ARTIFACT_DIRECTORY)
        if (!artifacts.exists()) return total
        val entries = artifacts.listFiles() ?: throw CrumbReportQueueException.StorageFailure()
        for (entry in entries) total = checkedPlus(total, fileByteSize(entry))
        return total
    }

    /** Zero for a confirmed-absent file; a storage failure for anything opaque. */
    private fun fileByteSize(file: File): Long {
        if (!file.exists()) return 0L
        val attributes = attributes(file)
        if (!attributes.isRegularFile || attributes.size() < 0) {
            throw CrumbReportQueueException.StorageFailure()
        }
        return attributes.size()
    }

    private fun attributes(file: File): BasicFileAttributes = try {
        Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
            .also { if (it.isSymbolicLink) throw CrumbReportQueueException.StorageFailure() }
    } catch (error: CrumbReportQueueException) {
        throw error
    } catch (_: Exception) {
        throw CrumbReportQueueException.StorageFailure()
    }

    private fun checkedPlus(lhs: Long, rhs: Long): Long = try {
        Math.addExact(lhs, rhs)
    } catch (_: ArithmeticException) {
        throw CrumbReportQueueException.StorageFailure()
    }

    /**
     * Separates three things that used to be one CorruptQueue:
     *
     * - an I/O failure reading the metadata stays a storage failure, so a
     *   protected or transiently unreadable file is retried, never quarantined;
     * - an unsupported schema version fails the whole operation, read before any
     *   version-specific field, so a future format is never treated as ordinary
     *   corruption or adopted;
     * - bytes read successfully and then rejected by supported-format decoding
     *   or shape validation, and a committed directory with positively no
     *   metadata, are isolated by returning null.
     */
    private fun readRecordOrNull(directory: File): StoredRecord? {
        for (file in directory.listFiles().orEmpty()) {
            if (file.name.startsWith(RECORD_TEMPORARY_PREFIX)) file.delete()
        }
        val recordFile = File(directory, RECORD_FILE)
        val properties = try {
            Properties().apply { FileInputStream(recordFile).use(::load) }
        } catch (error: IOException) {
            // Confirmed absent metadata in a directory that is still there is
            // isolatable. Anything else - unreadable, protected, a directory
            // where the file belongs - is a storage failure to retry.
            if (!recordFile.exists() && directory.isDirectory) return null
            throw CrumbReportQueueException.StorageFailure()
        } catch (_: Exception) {
            return null
        }
        val declaredVersion = properties.getProperty("schema_version")?.trim()?.toIntOrNull()
            ?: return null
        if (declaredVersion !in 1..2) throw CrumbReportQueueException.CorruptQueue()
        return decodeRecord(directory, properties, declaredVersion)
    }

    private fun decodeRecord(
        directory: File,
        properties: Properties,
        schemaVersion: Int,
    ): StoredRecord? {
        try {
            val artifactCount = properties.requiredInt("artifact_count")
            val artifacts = ArrayList<CrumbArtifactManifest>()
            for (index in 0 until artifactCount) {
                val prefix = "artifact.$index."
                val id = properties.required(prefix + "id")
                if (!validArtifactId(id) || properties.required(prefix + "file_name") != fileName(id)) {
                    return null
                }
                artifacts.add(CrumbArtifactManifest(
                    id = id,
                    kind = properties.required(prefix + "kind"),
                    mimeType = decode(properties.required(prefix + "mime_type")),
                    byteSize = properties.requiredLong(prefix + "byte_size"),
                    sha256 = properties.required(prefix + "sha256"),
                    redactionState = properties.required(prefix + "redaction_state"),
                    uploadId = properties.required(prefix + "upload_id"),
                ))
            }
            val record = StoredRecord(
                reportId = properties.required("report_id"),
                submittedAtMillis = properties.requiredLong("submitted_at_millis"),
                state = CrumbQueuedReportState.valueOf(properties.required("state")),
                attemptCount = properties.requiredInt("attempt_count"),
                lastError = properties.getProperty("last_error")?.let(::decode),
                totalByteSize = properties.requiredLong("total_byte_size"),
                envelopeByteSize = properties.requiredLong("envelope_byte_size"),
                envelopeSha256 = properties.required("envelope_sha256"),
                artifacts = artifacts,
                schemaVersion = schemaVersion,
                ownerFingerprint = if (schemaVersion == 2) {
                    properties.getProperty("owner_fingerprint")?.takeIf { it.matches(OWNER_FINGERPRINT_PATTERN) }
                } else null,
            )
            if (
                record.reportId != directory.name || record.attemptCount < 0 ||
                record.totalByteSize < 0 || record.envelopeByteSize < 0 ||
                artifacts.any {
                    it.byteSize < 0
                }
            ) {
                return null
            }
            return record
        } catch (_: CrumbReportQueueException.CorruptQueue) {
            // A missing or malformed field: bytes were read and the supported
            // format rejected them, so the entry isolates.
            return null
        } catch (error: CrumbReportQueueException) {
            // A storage failure is about the device, not this record.
            throw error
        } catch (_: Exception) {
            return null
        }
    }

    private fun writeRecord(directory: File, record: StoredRecord) {
        val properties = Properties().apply {
            setProperty("schema_version", record.schemaVersion.toString())
            record.ownerFingerprint?.let { setProperty("owner_fingerprint", it) }
            setProperty("report_id", record.reportId)
            setProperty("submitted_at_millis", record.submittedAtMillis.toString())
            setProperty("state", record.state.name)
            setProperty("attempt_count", record.attemptCount.toString())
            record.lastError?.let { setProperty("last_error", encode(it)) }
            setProperty("total_byte_size", record.totalByteSize.toString())
            setProperty("envelope_byte_size", record.envelopeByteSize.toString())
            setProperty("envelope_sha256", record.envelopeSha256)
            setProperty("artifact_count", record.artifacts.size.toString())
            for (index in record.artifacts.indices) {
                val artifact = record.artifacts[index]
                val prefix = "artifact.$index."
                setProperty(prefix + "id", artifact.id)
                setProperty(prefix + "kind", artifact.kind)
                setProperty(prefix + "mime_type", encode(artifact.mimeType))
                setProperty(prefix + "byte_size", artifact.byteSize.toString())
                setProperty(prefix + "sha256", artifact.sha256)
                setProperty(prefix + "redaction_state", artifact.redactionState)
                setProperty(prefix + "upload_id", artifact.uploadId)
                setProperty(prefix + "file_name", fileName(artifact.id))
            }
        }
        val temporary = File(directory, "$RECORD_TEMPORARY_PREFIX${UUID.randomUUID()}")
        try {
            FileOutputStream(temporary).use { stream ->
                properties.store(stream, null)
                stream.fd.sync()
            }
            atomicMove(temporary, File(directory, RECORD_FILE))
        } catch (_: Exception) {
            temporary.delete()
            throw CrumbReportQueueException.StorageFailure()
        }
    }

    private fun updateRecord(reportId: String, mutation: (StoredRecord) -> StoredRecord) {
        if (!validReportId(reportId)) throw CrumbReportQueueException.ReportNotFound()
        val directory = reportDirectory(reportId)
        if (!directory.isDirectory) throw CrumbReportQueueException.ReportNotFound()
        writeRecord(directory, mutation(readRecord(directory)))
    }

    private fun createDirectory(directory: File) {
        if ((!directory.exists() && !directory.mkdirs()) || !directory.isDirectory) {
            throw CrumbReportQueueException.StorageFailure()
        }
    }

    private fun writeDurably(file: File, bytes: ByteArray) {
        try {
            FileOutputStream(file).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
        } catch (_: Exception) {
            throw CrumbReportQueueException.StorageFailure()
        }
    }

    private fun readData(file: File): ByteArray = try {
        file.readBytes()
    } catch (_: Exception) {
        throw CrumbReportQueueException.CorruptQueue()
    }

    private fun atomicMove(source: File, destination: File) {
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            try {
                Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            } catch (_: Exception) {
                throw CrumbReportQueueException.StorageFailure()
            }
        } catch (_: Exception) {
            throw CrumbReportQueueException.StorageFailure()
        }
    }

    private fun reportDirectory(reportId: String) = File(root, reportId)

    private fun fileName(artifactId: String) = "$artifactId.blob"

    private fun sameArtifactBytes(
        first: List<CrumbQueueArtifact>,
        second: List<CrumbQueueArtifact>,
    ): Boolean {
        if (first.size != second.size) return false
        val secondById = second.associateBy { it.manifest.id }
        return first.all { artifact ->
            secondById[artifact.manifest.id]?.bytes?.contentEquals(artifact.bytes) == true
        }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun validReportId(value: String) = value.matches(Regex("^rpt_[A-Za-z0-9_-]{16,80}$"))

    private fun validArtifactId(value: String) = value.matches(Regex("^art_[A-Za-z0-9_-]{12,80}$"))

    private fun sanitizeReason(value: String) = value.replace('\n', ' ').replace('\r', ' ').take(512)

    private fun encode(value: String): String = Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString(value.toByteArray(Charsets.UTF_8))

    private fun decode(value: String): String = String(Base64.getUrlDecoder().decode(value), Charsets.UTF_8)

    private class StoredRecord(
        @JvmField val reportId: String,
        @JvmField val submittedAtMillis: Long,
        @JvmField val state: CrumbQueuedReportState,
        @JvmField val attemptCount: Int,
        @JvmField val lastError: String?,
        @JvmField val totalByteSize: Long,
        @JvmField val envelopeByteSize: Long,
        @JvmField val envelopeSha256: String,
        @JvmField val artifacts: List<CrumbArtifactManifest>,
        @JvmField val schemaVersion: Int,
        @JvmField val ownerFingerprint: String?,
    ) {
        fun copy(state: CrumbQueuedReportState = this.state, attemptCount: Int = this.attemptCount,
                 lastError: String? = this.lastError) = StoredRecord(reportId, submittedAtMillis, state,
            attemptCount, lastError, totalByteSize, envelopeByteSize, envelopeSha256, artifacts,
            schemaVersion, ownerFingerprint)

        fun summary() = CrumbQueuedReportSummary(
            reportId = reportId,
            submittedAtMillis = submittedAtMillis,
            state = state,
            attemptCount = attemptCount,
            lastError = lastError,
            totalByteSize = totalByteSize,
            artifactCount = artifacts.size,
        )
    }

    companion object {
        private const val ENVELOPE_FILE = "envelope.json"
        private const val RECORD_FILE = "record.properties"
        private const val ARTIFACT_DIRECTORY = "artifacts"
        private const val TEMPORARY_PREFIX = ".tmp-"
        private const val DELETE_PREFIX = ".delete-"
        private const val RECORD_TEMPORARY_PREFIX = ".record.tmp-"
        private val ARTIFACT_ID_PATTERN = Regex("\"id\":\"(art_[A-Za-z0-9_-]{12,80})\"")
        private val OWNER_FINGERPRINT_PATTERN = Regex("^[a-f0-9]{64}$")

        @Volatile
        private var shared: CrumbReportQueue? = null

        internal fun configured(root: File): CrumbReportQueue = CrumbReportQueue(root).also { queue ->
            queue.usesConfiguredOwner = true
        }

        @JvmSynthetic
        /**
         * The queue is single-process: its mutual exclusion is in-process only,
         * so two processes would interleave record writes and each admit
         * reports against the same quota. It refuses rather than let that drift
         * silently.
         *
         * [processName] defaults to this process and is a parameter so the
         * boundary is testable where the runtime cannot name its own process. A
         * process that cannot be named is treated as the main one: an
         * unidentifiable process must not break a working single-process host.
         */
        /** Null when the process cannot be named. No Context, no permission. */
        private fun currentProcessName(): String? = try {
            File("/proc/self/cmdline").readText().substringBefore('\u0000').trim().ifEmpty { null }
        } catch (_: Exception) {
            null
        }

        fun from(
            context: Context,
            processName: String? = currentProcessName(),
        ): CrumbReportQueue {
            if (processName != null && processName != context.packageName) {
                throw CrumbReportQueueException.UnsupportedProcess()
            }
            shared?.let { return it }
            return synchronized(this) {
                shared ?: configured(
                    File(File(context.noBackupFilesDir, "dev.crumb"), "reports"),
                ).also { shared = it }
            }
        }
    }
}

private fun Properties.required(key: String): String =
    getProperty(key) ?: throw CrumbReportQueueException.CorruptQueue()

private fun Properties.requiredInt(key: String): Int = required(key).toInt()

private fun Properties.requiredLong(key: String): Long = required(key).toLong()
