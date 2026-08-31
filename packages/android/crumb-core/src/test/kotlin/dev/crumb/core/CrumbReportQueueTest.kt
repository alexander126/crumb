package dev.crumb.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

class CrumbReportQueueTest {
    @Test
    fun defaultPayloadBudgetsMatchTheReleaseContract() {
        val limits = CrumbQueueLimits()
        assertEquals(1_048_576L, limits.maximumEnvelopeBytes)
        assertEquals(26_214_400L, limits.maximumArtifactBytes)
        assertEquals(27_262_976L, limits.maximumReportBytes)
    }

    @Test
    fun committedReportSurvivesAQueueRestartWithoutDuplication() {
        val root = temporaryRoot()
        try {
            val fixture = fixture("rpt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            val artifact = requireNotNull(fixture.artifact)
            val firstQueue = CrumbReportQueue(root)
            val first = firstQueue.enqueue(fixture.envelope, listOf(artifact))
            assertEquals(CrumbQueuedReportState.PENDING, first.state)
            assertEquals(1, first.artifactCount)

            val restartedQueue = CrumbReportQueue(root)
            val recovered = restartedQueue.reports()
            val payload = restartedQueue.load(fixture.envelope.reportId)
            val repeated = restartedQueue.enqueue(fixture.envelope, listOf(artifact))

            assertEquals(1, recovered.size)
            assertArrayEquals(fixture.envelope.json.toByteArray(), payload.envelope)
            assertArrayEquals(artifact.bytes, payload.artifacts.single().bytes)
            assertEquals(recovered.single(), repeated)
            assertEquals(1, restartedQueue.reports().size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun interruptedUploadReturnsToPendingAndFailureStatePersists() {
        val root = temporaryRoot()
        try {
            val fixture = fixture("rpt_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
            CrumbReportQueue(root).apply {
                enqueue(fixture.envelope, listOf(fixture.artifact!!))
                markUploading(fixture.envelope.reportId)
            }

            val restartedQueue = CrumbReportQueue(root)
            restartedQueue.recoverInterruptedUploads()
            var summary = restartedQueue.reports().single()
            assertEquals(CrumbQueuedReportState.PENDING, summary.state)
            assertEquals(1, summary.attemptCount)

            restartedQueue.markFailed(fixture.envelope.reportId, "offline\nretry later")
            summary = restartedQueue.reports().single()
            assertEquals(CrumbQueuedReportState.FAILED, summary.state)
            assertEquals("offline retry later", summary.lastError)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun queueLimitsRejectNewReportsWithoutEvictingCommittedReports() {
        val root = temporaryRoot()
        try {
            val queue = CrumbReportQueue(
                root,
                CrumbQueueLimits(
                    maximumReports = 1,
                    maximumTotalBytes = 2_048,
                    maximumReportBytes = 2_048,
                    maximumEnvelopeBytes = 1_024,
                    maximumArtifactBytes = 1_024,
                    maximumArtifactsPerReport = 1,
                ),
            )
            val first = fixture("rpt_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", artifactData = null)
            val second = fixture("rpt_DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", artifactData = null)
            queue.enqueue(first.envelope, emptyList())

            var rejected = false
            try {
                queue.enqueue(second.envelope, emptyList())
            } catch (_: CrumbReportQueueException.QueueFull) {
                rejected = true
            }
            assertTrue(rejected)
            assertEquals(listOf(first.envelope.reportId), queue.reports().map { it.reportId })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun startupRemovesOnlyUncommittedTemporaryTransactions() {
        val root = temporaryRoot()
        try {
            val orphan = File(root, ".tmp-interrupted")
            assertTrue(orphan.mkdirs())
            File(orphan, "envelope.json").writeText("partial")
            val tombstone = File(root, ".delete-accepted")
            assertTrue(tombstone.mkdirs())
            File(tombstone, "envelope.json").writeText("accepted")

            val queue = CrumbReportQueue(root)
            assertTrue(queue.reports().isEmpty())
            assertFalse(orphan.exists())
            assertFalse(tombstone.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun temporaryRoot() = Files.createTempDirectory("crumb-queue-tests-").toFile()

    private fun fixture(
        reportId: String,
        artifactData: ByteArray? = "masked-png".toByteArray(),
    ): Fixture {
        val artifactId = "art_0123456789ABCDEF"
        val digest = sha256(artifactData ?: ByteArray(0))
        val manifest = CrumbArtifactManifest(
            id = artifactId,
            kind = "screenshot",
            mimeType = "image/png",
            byteSize = artifactData?.size?.toLong() ?: 0,
            sha256 = digest,
            redactionState = "masked",
            uploadId = "upl_0123456789ABCDEF",
        )
        val artifacts = artifactData?.let {
            "[{\"id\":\"${manifest.id}\",\"kind\":\"${manifest.kind}\"," +
                "\"mime_type\":\"${manifest.mimeType}\",\"byte_size\":${manifest.byteSize}," +
                "\"sha256\":\"${manifest.sha256}\",\"redaction_state\":\"masked\"," +
                "\"upload_id\":\"${manifest.uploadId}\"}]"
        } ?: "[]"
        val json = "{\"schema_version\":\"1.0\",\"report_id\":\"$reportId\"," +
            "\"artifacts\":$artifacts}"
        return Fixture(
            envelope = CrumbSerializedReportEnvelope(
                reportId = reportId,
                submittedAtMillis = 1_700_000_000_000,
                json = json,
            ),
            artifact = artifactData?.let { CrumbQueueArtifact(manifest, it) },
        )
    }

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private data class Fixture(
        val envelope: CrumbSerializedReportEnvelope,
        val artifact: CrumbQueueArtifact?,
    )
}
