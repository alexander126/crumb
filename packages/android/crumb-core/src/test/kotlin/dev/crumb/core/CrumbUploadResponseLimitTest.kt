package dev.crumb.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest

class CrumbUploadResponseLimitTest {
    @Test
    fun boundedReadingStopsAtTheCeiling() {
        val body = ByteArray(2_048) { 'z'.code.toByte() }

        val read = ByteArrayInputStream(body).readBounded(maximumBytes = 2_048)

        assertArrayEquals(body, read)
    }

    @Test
    fun boundedReadingRefusesABodyAboveTheCeiling() {
        val body = ByteArray(2_049) { 'z'.code.toByte() }

        assertThrows(CrumbOversizedResponseException::class.java) {
            ByteArrayInputStream(body).readBounded(maximumBytes = 2_048)
        }
    }

    @Test
    fun anOversizedResponseIsTerminalAndKeepsTheReport() {
        assertClassification(
            failure = CrumbOversizedResponseException(),
            expectedError = "transport.response_too_large",
            shouldRetry = false,
        )
    }

    @Test
    fun agenuineTransportFailureStaysRetryable() {
        assertClassification(
            failure = IOException("synthetic connection reset"),
            expectedError = "init.network",
            shouldRetry = true,
        )
    }

    private fun assertClassification(
        failure: Exception,
        expectedError: String,
        shouldRetry: Boolean,
    ) {
        withOwnedReport { queue, root ->
            val before = queue.load(reportId)

            val result = CrumbReportUploadWorker(
                queue,
                CrumbUploadSettings(projectKey, destination),
                ThrowingTransport(failure),
            ).runPass()

            assertEquals(0, result.uploadedReportCount)
            assertEquals(1, result.remainingReportCount)
            assertEquals(shouldRetry, result.shouldRetry)
            assertFalse(result.wasCancelled)
            val retained = ownedQueue(root).load(reportId)
            assertEquals(CrumbQueuedReportState.FAILED, retained.summary.state)
            assertEquals(expectedError, retained.summary.lastError)
            assertArrayEquals(before.envelope, retained.envelope)
            assertTrue(retained.artifacts.isNotEmpty())
        }
    }

    private fun withOwnedReport(block: (CrumbReportQueue, File) -> Unit) {
        val root = Files.createTempDirectory("crumb-response-limit-").toFile()
        try {
            val bytes = "synthetic masked screenshot".toByteArray()
            val manifest = CrumbArtifactManifest(
                "art_0123456789ABCDEF",
                "screenshot",
                "image/png",
                bytes.size.toLong(),
                MessageDigest.getInstance("SHA-256").digest(bytes)
                    .joinToString("") { "%02x".format(it.toInt() and 0xff) },
                "masked",
                "upl_0123456789ABCDEF",
            )
            val envelope = JSONObject().put("schema_version", "1.0").put("report_id", reportId)
                .put(
                    "artifacts",
                    JSONArray().put(
                        JSONObject()
                            .put("id", manifest.id).put("kind", manifest.kind)
                            .put("mime_type", manifest.mimeType).put("byte_size", manifest.byteSize)
                            .put("sha256", manifest.sha256)
                            .put("redaction_state", manifest.redactionState)
                            .put("upload_id", manifest.uploadId),
                    ),
                )
            val queue = ownedQueue(root)
            queue.enqueue(
                CrumbSerializedReportEnvelope(reportId, 1_700_000_000_000, envelope.toString()),
                listOf(CrumbQueueArtifact(manifest, bytes)),
            )
            block(queue, root)
        } finally {
            root.deleteRecursively()
        }
    }

    private fun ownedQueue(root: File) =
        CrumbReportQueue(root, CrumbQueueOwnerFingerprint.from(projectKey, destination))

    private class ThrowingTransport(private val failure: Exception) : CrumbUploadTransport {
        override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse = throw failure
    }

    private companion object {
        const val reportId = "rpt_ResponseLimitAAAAAAAAAAAAAAAAAA"
        const val projectKey = "synthetic_response_limit_write_key"
        const val destination = "https://response-limit.example.invalid"
    }
}
