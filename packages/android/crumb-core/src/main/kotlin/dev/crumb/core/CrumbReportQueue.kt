package dev.crumb.core

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
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
}

class CrumbReportQueue internal constructor(
    private val root: File,
    private val limits: CrumbQueueLimits = CrumbQueueLimits(),
) {
    @Synchronized
    fun enqueue(
        envelope: CrumbSerializedReportEnvelope,
        artifacts: List<CrumbQueueArtifact>,
    ): CrumbQueuedReportSummary {
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
            val existing = load(envelope.reportId)
            if (!existing.envelope.contentEquals(envelopeBytes) ||
                !sameArtifactBytes(existing.artifacts, artifacts)
            ) {
                throw CrumbReportQueueException.ConflictingReport()
            }
            return existing.summary
        }

        val existingRecords = readAllRecords()
        if (
            existingRecords.size >= limits.maximumReports ||
            existingRecords.sumOf(StoredRecord::totalByteSize) + totalByteSize > limits.maximumTotalBytes
        ) {
            throw CrumbReportQueueException.QueueFull()
        }

        val temporary = File(root, ".tmp-${UUID.randomUUID()}")
        try {
            createDirectory(temporary)
            val artifactDirectory = File(temporary, ARTIFACT_DIRECTORY)
            if (artifacts.isNotEmpty()) createDirectory(artifactDirectory)

            writeDurably(File(temporary, ENVELOPE_FILE), envelopeBytes)
            artifacts.forEach { artifact ->
                writeDurably(File(artifactDirectory, fileName(artifact.manifest.id)), artifact.bytes)
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
                artifacts = artifacts.map(::StoredArtifact),
            )
            writeRecord(temporary, record)
            atomicMove(temporary, destination)
            return record.summary()
        } catch (error: CrumbReportQueueException) {
            temporary.deleteRecursively()
            throw error
        } catch (_: Exception) {
            temporary.deleteRecursively()
            throw CrumbReportQueueException.StorageFailure()
        }
    }

    @Synchronized
    fun reports(): List<CrumbQueuedReportSummary> {
        validateLimits()
        prepareRoot()
        cleanupTemporaryTransactions()
        return readAllRecords()
            .sortedBy(StoredRecord::submittedAtMillis)
            .map(StoredRecord::summary)
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
        val artifacts = record.artifacts.map { stored ->
            val bytes = readData(File(File(directory, ARTIFACT_DIRECTORY), stored.fileName))
            if (bytes.size.toLong() != stored.byteSize || sha256(bytes) != stored.sha256) {
                throw CrumbReportQueueException.CorruptQueue()
            }
            CrumbQueueArtifact(stored.manifest(), bytes)
        }
        if (envelope.size.toLong() + artifacts.sumOf { it.bytes.size.toLong() } != record.totalByteSize) {
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
        tombstone.deleteRecursively()
    }

    /** Upload work interrupted by process termination becomes retryable on the next launch. */
    @Synchronized
    fun recoverInterruptedUploads() {
        prepareRoot()
        cleanupTemporaryTransactions()
        readAllRecords()
            .filter { it.state == CrumbQueuedReportState.UPLOADING }
            .forEach { record ->
                updateRecord(record.reportId) { it.copy(state = CrumbQueuedReportState.PENDING, lastError = null) }
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
            artifacts.map { it.manifest.id }.toSet().size != artifacts.size ||
            !validReportId(envelope.reportId) ||
            !envelope.json.contains("\"report_id\":\"${envelope.reportId}\"")
        ) {
            throw CrumbReportQueueException.InvalidEnvelope()
        }
        val envelopeArtifactIds = ARTIFACT_ID_PATTERN.findAll(envelope.json)
            .map { it.groupValues[1] }
            .toList()
        if (envelopeArtifactIds.toSet() != artifacts.map { it.manifest.id }.toSet() ||
            envelopeArtifactIds.size != artifacts.size
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
        root.listFiles()
            ?.filter { it.name.startsWith(TEMPORARY_PREFIX) || it.name.startsWith(DELETE_PREFIX) }
            ?.forEach(File::deleteRecursively)
    }

    private fun readAllRecords(): List<StoredRecord> = try {
        root.listFiles()
            ?.filter {
                it.isDirectory && !it.name.startsWith(TEMPORARY_PREFIX) &&
                    !it.name.startsWith(DELETE_PREFIX)
            }
            ?.map(::readRecord)
            .orEmpty()
    } catch (error: CrumbReportQueueException) {
        throw error
    } catch (_: Exception) {
        throw CrumbReportQueueException.CorruptQueue()
    }

    private fun readRecord(directory: File): StoredRecord {
        try {
            directory.listFiles()
                ?.filter { it.name.startsWith(RECORD_TEMPORARY_PREFIX) }
                ?.forEach(File::delete)
            val properties = Properties().apply {
                FileInputStream(File(directory, RECORD_FILE)).use(::load)
            }
            val artifactCount = properties.requiredInt("artifact_count")
            val artifacts = (0 until artifactCount).map { index ->
                val prefix = "artifact.$index."
                StoredArtifact(
                    id = properties.required(prefix + "id"),
                    kind = properties.required(prefix + "kind"),
                    mimeType = decode(properties.required(prefix + "mime_type")),
                    byteSize = properties.requiredLong(prefix + "byte_size"),
                    sha256 = properties.required(prefix + "sha256"),
                    redactionState = properties.required(prefix + "redaction_state"),
                    uploadId = properties.required(prefix + "upload_id"),
                    fileName = properties.required(prefix + "file_name"),
                )
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
            )
            if (
                properties.requiredInt("schema_version") != 1 ||
                record.reportId != directory.name || record.attemptCount < 0 ||
                record.totalByteSize < 0 || record.envelopeByteSize < 0 ||
                artifacts.any {
                    !validArtifactId(it.id) || it.fileName != fileName(it.id) || it.byteSize < 0
                }
            ) {
                throw CrumbReportQueueException.CorruptQueue()
            }
            return record
        } catch (error: CrumbReportQueueException) {
            throw error
        } catch (_: Exception) {
            throw CrumbReportQueueException.CorruptQueue()
        }
    }

    private fun writeRecord(directory: File, record: StoredRecord) {
        val properties = Properties().apply {
            setProperty("schema_version", "1")
            setProperty("report_id", record.reportId)
            setProperty("submitted_at_millis", record.submittedAtMillis.toString())
            setProperty("state", record.state.name)
            setProperty("attempt_count", record.attemptCount.toString())
            record.lastError?.let { setProperty("last_error", encode(it)) }
            setProperty("total_byte_size", record.totalByteSize.toString())
            setProperty("envelope_byte_size", record.envelopeByteSize.toString())
            setProperty("envelope_sha256", record.envelopeSha256)
            setProperty("artifact_count", record.artifacts.size.toString())
            record.artifacts.forEachIndexed { index, artifact ->
                val prefix = "artifact.$index."
                setProperty(prefix + "id", artifact.id)
                setProperty(prefix + "kind", artifact.kind)
                setProperty(prefix + "mime_type", encode(artifact.mimeType))
                setProperty(prefix + "byte_size", artifact.byteSize.toString())
                setProperty(prefix + "sha256", artifact.sha256)
                setProperty(prefix + "redaction_state", artifact.redactionState)
                setProperty(prefix + "upload_id", artifact.uploadId)
                setProperty(prefix + "file_name", artifact.fileName)
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

    private data class StoredRecord(
        val reportId: String,
        val submittedAtMillis: Long,
        val state: CrumbQueuedReportState,
        val attemptCount: Int,
        val lastError: String?,
        val totalByteSize: Long,
        val envelopeByteSize: Long,
        val envelopeSha256: String,
        val artifacts: List<StoredArtifact>,
    ) {
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

    private data class StoredArtifact(
        val id: String,
        val kind: String,
        val mimeType: String,
        val byteSize: Long,
        val sha256: String,
        val redactionState: String,
        val uploadId: String,
        val fileName: String,
    ) {
        constructor(artifact: CrumbQueueArtifact) : this(
            id = artifact.manifest.id,
            kind = artifact.manifest.kind,
            mimeType = artifact.manifest.mimeType,
            byteSize = artifact.manifest.byteSize,
            sha256 = artifact.manifest.sha256,
            redactionState = artifact.manifest.redactionState,
            uploadId = artifact.manifest.uploadId,
            fileName = "${artifact.manifest.id}.blob",
        )

        fun manifest() = CrumbArtifactManifest(
            id = id,
            kind = kind,
            mimeType = mimeType,
            byteSize = byteSize,
            sha256 = sha256,
            redactionState = redactionState,
            uploadId = uploadId,
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

        @Volatile
        private var shared: CrumbReportQueue? = null

        @JvmSynthetic
        fun from(context: Context): CrumbReportQueue {
            shared?.let { return it }
            return synchronized(this) {
                shared ?: CrumbReportQueue(
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
