package dev.crumb.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CrumbReportUploaderTest {
    @Test
    fun offlineReportUploadsExactlyOnceAfterConnectivityReturns() {
        withTemporaryQueue { queue ->
            val fixture = fixture()
            queue.enqueue(fixture.envelope, listOf(fixture.artifact))
            val transport = ConnectivityTransport(
                fixture.envelope.reportId,
                fixture.artifact.manifest.id,
                fixture.artifact.manifest.uploadId,
                fixture.envelope.json.toByteArray().size,
                fixture.artifact.bytes.size,
            )
            val worker = CrumbReportUploadWorker(
                queue,
                CrumbUploadSettings("write_test_key", "https://ingestion.example.test"),
                transport,
            )

            val offline = worker.runPass()
            assertEquals(0, offline.uploadedReportCount)
            assertEquals(1, offline.remainingReportCount)
            assertTrue(offline.shouldRetry)
            queue.reports().single().also { failed ->
                assertEquals(CrumbQueuedReportState.FAILED, failed.state)
                assertEquals(1, failed.attemptCount)
                assertEquals("init.network", failed.lastError)
            }

            transport.online = true
            val reconnected = worker.runPass()
            val drainedAgain = worker.runPass()

            assertEquals(1, reconnected.uploadedReportCount)
            assertEquals(0, reconnected.remainingReportCount)
            assertFalse(reconnected.shouldRetry)
            assertEquals(0, drainedAgain.uploadedReportCount)
            assertEquals(2, transport.initRequests)
            assertEquals(1, transport.artifactUploads)
            assertEquals(1, transport.completions)
            assertTrue(queue.reports().isEmpty())
        }
    }

    @Test
    fun cancellingAnInFlightPassReturnsTheReportToPending() {
        withTemporaryQueue { queue ->
            val fixture = fixture("rpt_CancelAAAAAAAAAAAAAAAAAAAAAAAAAA")
            queue.enqueue(fixture.envelope, listOf(fixture.artifact))
            val transport = BlockingTransport()
            val worker = CrumbReportUploadWorker(
                queue,
                CrumbUploadSettings("write_test_key", "https://ingestion.example.test"),
                transport,
            )
            val executor = Executors.newSingleThreadExecutor()
            try {
                val result = executor.submit<CrumbUploadPassResult>(worker::runPass)
                assertTrue(transport.started.await(2, TimeUnit.SECONDS))
                worker.cancel()
                val cancelled = result.get(2, TimeUnit.SECONDS)
                val summary = queue.reports().single()

                assertTrue(cancelled.wasCancelled)
                assertEquals(CrumbQueuedReportState.PENDING, summary.state)
                assertEquals(1, summary.attemptCount)
            } finally {
                executor.shutdownNow()
            }
        }
    }

    private fun withTemporaryQueue(block: (CrumbReportQueue) -> Unit) {
        val root = Files.createTempDirectory("crumb-uploader-tests").toFile()
        try {
            block(CrumbReportQueue(root))
        } finally {
            root.deleteRecursively()
        }
    }

    private fun fixture(
        reportId: String = "rpt_OfflineAAAAAAAAAAAAAAAAAAAAAAAAA",
    ): Fixture {
        val bytes = "masked-png".toByteArray()
        val manifest = CrumbArtifactManifest(
            id = "art_0123456789ABCDEF",
            kind = "screenshot",
            mimeType = "image/png",
            byteSize = bytes.size.toLong(),
            sha256 = sha256(bytes),
            redactionState = "masked",
            uploadId = "upl_0123456789ABCDEF",
        )
        val envelope = """
            {"schema_version":"1.0","report_id":"$reportId","artifacts":[{"id":"${manifest.id}","kind":"${manifest.kind}","mime_type":"${manifest.mimeType}","byte_size":${manifest.byteSize},"sha256":"${manifest.sha256}","redaction_state":"${manifest.redactionState}","upload_id":"${manifest.uploadId}"}]}
        """.trimIndent()
        return Fixture(
            CrumbSerializedReportEnvelope(reportId, 1_700_000_000_000, envelope),
            CrumbQueueArtifact(manifest, bytes),
        )
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private data class Fixture(
        val envelope: CrumbSerializedReportEnvelope,
        val artifact: CrumbQueueArtifact,
    )

    private class ConnectivityTransport(
        private val reportId: String,
        private val artifactId: String,
        private val uploadId: String,
        private val envelopeByteCount: Int,
        private val artifactByteCount: Int,
    ) : CrumbUploadTransport {
        var online = false
        var initRequests = 0
        var artifactUploads = 0
        var completions = 0

        override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse {
            return when {
                request.url.endsWith("/init") -> {
                    initRequests += 1
                    assertEquals("Bearer write_test_key", request.headers["Authorization"])
                    assertEquals("$reportId:init", request.headers["Idempotency-Key"])
                    assertTrue(checkNotNull(request.body).size - envelopeByteCount <= 65_536)
                    if (!online) throw IOException("offline")
                    CrumbUploadHttpResponse(
                        201,
                        """
                            {"report_id":"$reportId","status":"initialized","artifacts":[{"id":"$artifactId","upload_id":"$uploadId","method":"PUT","url":"https://objects.example.test/signed/$artifactId","headers":{"content-type":"image/png"},"expires_at":"2026-08-24T23:59:59.000Z"}]}
                        """.trimIndent().toByteArray(),
                    )
                }
                request.url.startsWith("https://objects.example.test/") -> {
                    artifactUploads += 1
                    assertEquals(artifactByteCount, request.body?.size)
                    CrumbUploadHttpResponse(200)
                }
                request.url.endsWith("/complete") -> {
                    completions += 1
                    assertEquals("$reportId:complete", request.headers["Idempotency-Key"])
                    assertEquals("application/json", request.headers["Content-Type"])
                    assertEquals("{}", String(checkNotNull(request.body)))
                    CrumbUploadHttpResponse(200)
                }
                else -> CrumbUploadHttpResponse(404)
            }
        }
    }

    private class BlockingTransport : CrumbUploadTransport {
        val started = CountDownLatch(1)
        private val released = CountDownLatch(1)

        override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse {
            started.countDown()
            released.await(60, TimeUnit.SECONDS)
            return CrumbUploadHttpResponse(500)
        }

        override fun cancel() {
            released.countDown()
        }
    }
}
