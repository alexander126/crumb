package dev.crumb.core

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.lang.reflect.Modifier
import java.nio.file.Files
import java.security.MessageDigest

class CrumbTerminalUploadRetryTest {
    @Test
    fun automaticPassDoesNotReofferRejectedReportWhenSiblingRetries() = automaticPass(false)

    @Test
    fun automaticPassDoesNotReofferInvalidCompletionWhenSiblingRetries() = automaticPass(true)

    private fun automaticPass(invalidCompletion: Boolean) {
            val root = Files.createTempDirectory("crumb-terminal-").toFile()
            try {
                val settings = CrumbUploadSettings("synthetic-terminal-key", "https://ingestion.example.invalid")
                val queue = CrumbReportQueue(root, CrumbQueueOwnerFingerprint.from(settings.projectKey, settings.ingestionUrl))
                val oldest = fixture("rpt_TerminalAAAAAAAAAAAAAAAAAAAAAAAAA", 0)
                val sibling = fixture("rpt_TransientBBBBBBBBBBBBBBBBBBBBBBBB", 1)
                for ((envelope, artifact) in listOf(oldest, sibling)) queue.enqueue(envelope, listOf(artifact))
                val transport = TerminalTransport(oldest.first.reportId, sibling.first.reportId, invalidCompletion)
                val worker = CrumbReportUploadWorker(queue, settings, transport)

                worker.prepareForPass()
                assertTrue(worker.runPass().shouldRetry)
                val failed = queue.load(oldest.first.reportId)
                assertEquals(CrumbQueuedReportState.FAILED, failed.summary.state)
                assertEquals(1, failed.summary.attemptCount)
                assertEquals(if (invalidCompletion) "complete.invalid_response" else "init.http_422", failed.summary.lastError)
                val record = File(File(root, oldest.first.reportId), "record.properties")
                val stored = record.readBytes()

                worker.prepareForPass()
                val automatic = worker.runPass()

                assertTrue(automatic.shouldRetry)
                assertEquals(2, automatic.remainingReportCount)
                assertEquals(1, transport.counts[oldest.first.reportId])
                assertEquals(2, transport.counts[sibling.first.reportId])
                assertEquals(failed.summary, queue.load(oldest.first.reportId).summary)
                assertArrayEquals(failed.envelope, queue.load(oldest.first.reportId).envelope)
                assertArrayEquals(failed.artifacts.single().bytes, queue.load(oldest.first.reportId).artifacts.single().bytes)
                assertArrayEquals(stored, record.readBytes())
                assertEquals(2, queue.load(sibling.first.reportId).summary.attemptCount)

                transport.transientAllowed = true
                val newReport = fixture("rpt_NewCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", 2)
                queue.enqueue(newReport.first, listOf(newReport.second))
                worker.prepareForPass()
                val progress = worker.runPass()
                assertEquals(2, progress.uploadedReportCount)
                assertEquals(1, progress.remainingReportCount)
                assertFalse(progress.shouldRetry)
                assertEquals(1, transport.counts[oldest.first.reportId])
                assertEquals(failed.summary, queue.load(oldest.first.reportId).summary)
                assertArrayEquals(stored, record.readBytes())

                // Failed enumeration must not discard the remembered terminal
                // classification. The failure has to be genuine I/O: malformed
                // metadata is now isolated per item rather than failing the
                // scan, and a permission bit would not hold when tests run as
                // root. A directory where the metadata file belongs fails the
                // read for every uid.
                assertTrue(record.delete())
                assertTrue(record.mkdir())
                assertTrue(worker.runPass().shouldRetry)
                assertTrue(record.delete())
                record.writeBytes(stored)
                assertFalse(worker.runPass().shouldRetry)
                assertEquals(1, transport.counts[oldest.first.reportId])

                worker.prepareForForegroundPass()
                val foreground = worker.runPass()
                assertFalse(foreground.shouldRetry)
                assertEquals(1, foreground.remainingReportCount)
                assertEquals(2, transport.counts[oldest.first.reportId])
                assertEquals(2, queue.load(oldest.first.reportId).summary.attemptCount)

                queue.markPending(oldest.first.reportId)
                worker.runPass()
                assertEquals(3, transport.counts[oldest.first.reportId])
                queue.remove(oldest.first.reportId)
                queue.enqueue(oldest.first, listOf(oldest.second))
                worker.runPass()
                assertEquals(4, transport.counts[oldest.first.reportId])
                assertEquals(1, queue.load(oldest.first.reportId).summary.attemptCount)
            } finally {
                root.deleteRecursively()
            }
    }

    @Test
    fun preservesNoArgumentJvmDeliveryControls() {
        for ((name, result) in listOf("prepareForPass" to Void.TYPE, "runPass" to CrumbUploadPassResult::class.java)) {
            val method = CrumbReportUploadWorker::class.java.getDeclaredMethod(name)
            assertEquals(result, method.returnType)
            assertTrue(Modifier.isPublic(method.modifiers))
            assertTrue(method.isSynthetic)
        }
    }

    private fun fixture(id: String, offset: Long): Pair<CrumbSerializedReportEnvelope, CrumbQueueArtifact> {
        val bytes = "synthetic masked screenshot".toByteArray()
        val artifact = CrumbArtifactManifest("art_0123456789ABCDEF", "screenshot", "image/png", bytes.size.toLong(),
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }, "masked", "upl_0123456789ABCDEF")
        val envelope = """{"schema_version":"1.0","report_id":"$id","artifacts":[{"id":"${artifact.id}","kind":"${artifact.kind}","mime_type":"${artifact.mimeType}","byte_size":${artifact.byteSize},"sha256":"${artifact.sha256}","redaction_state":"${artifact.redactionState}","upload_id":"${artifact.uploadId}"}]}"""
        return CrumbSerializedReportEnvelope(id, 1_700_000_000_000 + offset, envelope) to CrumbQueueArtifact(artifact, bytes)
    }

    private class TerminalTransport(val terminalId: String, val transientId: String, val invalidCompletion: Boolean) : CrumbUploadTransport {
        val counts = HashMap<String, Int>()
        var transientAllowed = false
        override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse {
            if (request.url.endsWith("/init")) {
                val id = JSONObject(String(checkNotNull(request.body))).getJSONObject("envelope").getString("report_id")
                counts[id] = (counts[id] ?: 0) + 1
                if (id == transientId && !transientAllowed) return CrumbUploadHttpResponse(503)
                if (id == terminalId && !invalidCompletion) return CrumbUploadHttpResponse(422)
                return CrumbUploadHttpResponse(201, """{"report_id":"$id","status":"initialized","artifacts":[{"id":"art_0123456789ABCDEF","upload_id":"upl_0123456789ABCDEF","method":"PUT","url":"https://objects.example.invalid/synthetic","headers":{}}]}""".toByteArray())
            }
            if (request.method == "PUT") return CrumbUploadHttpResponse(200)
            assertTrue(request.url.endsWith("/complete"))
            val body = if (request.url.contains(terminalId)) """{"status":"processing"}""" else """{"status":"accepted"}"""
            return CrumbUploadHttpResponse(202, body.toByteArray())
        }
    }
}
