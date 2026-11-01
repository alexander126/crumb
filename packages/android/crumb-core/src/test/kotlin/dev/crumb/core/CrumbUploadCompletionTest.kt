package dev.crumb.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Properties

class CrumbUploadCompletionTest {
    @Test
    fun invalidCompletionsPreserveTheOwnedReport() {
        val responses = listOf(
            202 to """{"status":"processing"}""",
            200 to """{"status":"initialized"}""",
            200 to """{"detail":"synthetic-response-detail https://response.example.invalid"}""",
            200 to """{"status":null}""",
            200 to """{"status":202}""",
            200 to """{"status":true}""",
            200 to """{"status":["accepted"]}""",
            200 to """{"status":"Accepted"}""",
            200 to """{"status":" accepted "}""",
            200 to """[{"status":"accepted"}]""",
            200 to "\"accepted\"",
            200 to "null",
            200 to "",
            200 to """{"status":""",
            200 to """{"status":"accepted"} trailing-data""",
            200 to "{\"status\":\"accepted\"}\u0000",
            200 to "{\"status\":\"accepted\"}\u0001",
            200 to """{"status":"accepted"} {"status":"processing"}""",
            200 to """{"status":"accepted","report_id":"rpt_OtherAAAAAAAAAAAAAAAAAAAAAAAAAAA"}""",
            200 to """{"status":"accepted","report_id":null}""",
            200 to """{"status":"accepted","report_id":42}""",
            200 to """{"status":"accepted","report_id":true}""",
            200 to """{"status":"accepted","report_id":{}}""",
            200 to """{"status":"accepted","report_id":[]}""",
        )
        responses.forEach { (statusCode, body) -> assertRetained(statusCode, body) }
    }

    @Test
    fun alreadyAcceptedInitializationStillRequiresAcceptedCompletion() {
        assertRetained(202, """{"status":"processing"}""", alreadyAccepted = true)
    }

    @Test
    fun acceptedCompletionsRemoveExactlyOnce() {
        val responses = listOf(
            Triple(200, """{"status":"accepted"}""", false),
            Triple(202, """{"status":"accepted"}""", false),
            Triple(200, " \t\r\n{\"status\":\"accepted\"} \t\r\n", false),
            Triple(200, """{"status":"accepted","extra":"\u0000"}""", false),
            Triple(200, """{"status":"accepted","report_id":"$reportId"}""", false),
            Triple(200, """{"status":"accepted"}""", true),
            Triple(202, """{"status":"accepted","report_id":"$reportId","extra":{"value":null}}""", true),
        )
        responses.forEach { (statusCode, body, alreadyAccepted) ->
            withOwnedReport { queue, _, artifact ->
                val transport = CompletionTransport(artifact, CrumbUploadHttpResponse(statusCode, body.toByteArray()), alreadyAccepted)
                val worker = CrumbReportUploadWorker(queue, settings(), transport)

                val result = worker.runPass()
                val secondPass = worker.runPass()

                assertEquals(1, result.uploadedReportCount)
                assertEquals(0, result.remainingReportCount)
                assertFalse(result.shouldRetry)
                assertEquals(0, secondPass.uploadedReportCount)
                assertTrue(queue.reports().isEmpty())
                assertEquals(1, transport.initializations)
                assertEquals(if (alreadyAccepted) 0 else 1, transport.artifacts)
                assertEquals(1, transport.completions)
            }
        }
    }

    @Test
    fun completionHttpFailuresKeepExistingRetryClassification() {
        listOf(408 to true, 429 to true, 500 to true, 401 to false).forEach { (code, retryable) ->
            assertRetained(
                code, """{"status":"accepted"}""", expectedError = "complete.http_$code", shouldRetry = retryable,
            )
        }
    }

    private fun assertRetained(
        statusCode: Int,
        body: String,
        alreadyAccepted: Boolean = false,
        expectedError: String = "complete.invalid_response",
        shouldRetry: Boolean = false,
    ) {
        withOwnedReport { queue, root, artifact ->
            val before = queue.load(reportId)
            val transport = CompletionTransport(artifact, CrumbUploadHttpResponse(statusCode, body.toByteArray()), alreadyAccepted)

            val result = CrumbReportUploadWorker(queue, settings(), transport).runPass()

            assertEquals("completion must not delete this local report: $body", 0, result.uploadedReportCount)
            assertEquals(1, result.remainingReportCount)
            assertEquals(shouldRetry, result.shouldRetry)
            assertFalse(result.wasCancelled)
            assertEquals(1, transport.initializations)
            assertEquals(if (alreadyAccepted) 0 else 1, transport.artifacts)
            assertEquals(1, transport.completions)
            val retained = ownedQueue(root).load(reportId)
            assertArrayEquals(before.envelope, retained.envelope)
            assertEquals(before.artifacts.single().manifest, retained.artifacts.single().manifest)
            assertArrayEquals(before.artifacts.single().bytes, retained.artifacts.single().bytes)
            assertEquals(CrumbQueuedReportState.FAILED, retained.summary.state)
            assertEquals(1, retained.summary.attemptCount)
            assertEquals(expectedError, retained.summary.lastError)
            assertEquals(before.summary.totalByteSize, retained.summary.totalByteSize)
            assertEquals(1, retained.summary.artifactCount)
            val recordFile = File(File(root, reportId), "record.properties")
            val record = Properties().apply { recordFile.inputStream().use(::load) }
            assertEquals("2", record.getProperty("schema_version"))
            assertEquals(CrumbQueueOwnerFingerprint.from(projectKey, destination), record.getProperty("owner_fingerprint"))
            val metadata = recordFile.readText()
            assertFalse(metadata.contains(projectKey))
            assertFalse(metadata.contains(destination))
            assertFalse(metadata.contains("synthetic-response-detail"))
        }
    }

    private fun withOwnedReport(block: (CrumbReportQueue, File, CrumbQueueArtifact) -> Unit) {
        val root = Files.createTempDirectory("crumb-completion-").toFile()
        try {
            val bytes = "synthetic masked screenshot".toByteArray()
            val manifest = CrumbArtifactManifest(
                "art_0123456789ABCDEF", "screenshot", "image/png", bytes.size.toLong(),
                MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) },
                "masked", "upl_0123456789ABCDEF",
            )
            val envelope = JSONObject().put("schema_version", "1.0").put("report_id", reportId)
                .put("artifacts", JSONArray().put(JSONObject()
                    .put("id", manifest.id).put("kind", manifest.kind).put("mime_type", manifest.mimeType)
                    .put("byte_size", manifest.byteSize).put("sha256", manifest.sha256)
                    .put("redaction_state", manifest.redactionState).put("upload_id", manifest.uploadId)))
            val queue = ownedQueue(root)
            val artifact = CrumbQueueArtifact(manifest, bytes)
            queue.enqueue(CrumbSerializedReportEnvelope(reportId, 1_700_000_000_000, envelope.toString()), listOf(artifact))
            block(queue, root, artifact)
        } finally {
            root.deleteRecursively()
        }
    }

    private fun ownedQueue(root: File) = CrumbReportQueue(root, CrumbQueueOwnerFingerprint.from(projectKey, destination))

    private fun settings() = CrumbUploadSettings(projectKey, destination)

    private class CompletionTransport(
        private val artifact: CrumbQueueArtifact,
        private val completion: CrumbUploadHttpResponse,
        private val alreadyAccepted: Boolean,
    ) : CrumbUploadTransport {
        var initializations = 0
        var artifacts = 0
        var completions = 0

        override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse {
            if (request.url.endsWith("/init")) {
                initializations += 1
                val targets = JSONArray()
                if (!alreadyAccepted) targets.put(JSONObject()
                    .put("id", artifact.manifest.id).put("upload_id", artifact.manifest.uploadId).put("method", "PUT")
                    .put("url", "https://objects.example.invalid/synthetic")
                    .put("headers", JSONObject().put("content-type", "image/png")))
                return CrumbUploadHttpResponse(200, JSONObject().put("report_id", reportId)
                    .put("status", if (alreadyAccepted) "accepted" else "initialized")
                    .put("artifacts", targets).toString().toByteArray())
            }
            if (request.method == "PUT") {
                artifacts += 1
                assertArrayEquals(artifact.bytes, request.body)
                return CrumbUploadHttpResponse(200)
            }
            completions += 1
            assertTrue(request.url.endsWith("/complete"))
            assertEquals("$reportId:complete", request.headers["Idempotency-Key"])
            return completion
        }
    }

    private companion object {
        const val reportId = "rpt_CompletionAAAAAAAAAAAAAAAAAAAAAA"
        const val projectKey = "synthetic_completion_write_key"
        const val destination = "https://completion.example.invalid"
    }
}
