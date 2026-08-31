package dev.crumb.core

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

data class CrumbUploadHttpRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val body: ByteArray?,
    val timeoutMillis: Int,
)

data class CrumbUploadHttpResponse(
    val statusCode: Int,
    val body: ByteArray = ByteArray(0),
)

fun interface CrumbUploadTransport {
    fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse

    fun cancel() = Unit
}

data class CrumbUploadPassResult(
    val uploadedReportCount: Int,
    val remainingReportCount: Int,
    val shouldRetry: Boolean,
    val wasCancelled: Boolean,
)

/** Performs one bounded upload pass. Scheduling and connectivity live in crumb-ui. */
class CrumbReportUploadWorker internal constructor(
    private val queue: CrumbReportQueue,
    private val settings: CrumbUploadSettings,
    private val transport: CrumbUploadTransport,
) {
    private val cancelled = AtomicBoolean(false)

    @JvmSynthetic
    fun prepareForPass() {
        cancelled.set(false)
    }

    @JvmSynthetic
    fun cancel() {
        cancelled.set(true)
        transport.cancel()
    }

    @JvmSynthetic
    fun runPass(): CrumbUploadPassResult {
        var uploadedReportCount = 0
        var shouldRetry = false
        var wasCancelled = false

        try {
            queue.recoverInterruptedUploads()
            for (report in queue.reports()) {
                try {
                    checkCancellation()
                    queue.markUploading(report.reportId)
                    val payload = queue.load(report.reportId)
                    upload(payload)
                    checkCancellation()
                    queue.remove(report.reportId)
                    uploadedReportCount += 1
                } catch (_: CancellationException) {
                    runCatching { queue.markPending(report.reportId) }
                    wasCancelled = true
                    break
                } catch (failure: CrumbUploadFailure) {
                    runCatching { queue.markFailed(report.reportId, failure.reason) }
                    if (failure.retryable) {
                        shouldRetry = true
                        break
                    }
                } catch (_: Exception) {
                    runCatching { queue.markFailed(report.reportId, "uploader.local_failure") }
                }
            }
        } catch (_: CancellationException) {
            wasCancelled = true
        } catch (_: Exception) {
            shouldRetry = true
        }

        val remainingReportCount = runCatching { queue.reports().size }.getOrDefault(1)
        return CrumbUploadPassResult(
            uploadedReportCount = uploadedReportCount,
            remainingReportCount = remainingReportCount,
            shouldRetry = shouldRetry,
            wasCancelled = wasCancelled,
        )
    }

    private fun upload(payload: CrumbQueuedReportPayload) {
        val reportId = payload.summary.reportId
        val initialized = decodeInitialization(
            sendLifecycle(
                components = listOf("sdk", "v1", "reports", "init"),
                reportId = reportId,
                operation = "init",
                body = wrapEnvelope(payload.envelope),
            ).body,
            reportId,
        )

        when (initialized.status) {
            "accepted" -> if (initialized.artifacts.isNotEmpty()) {
                throw CrumbUploadFailure("init.invalid_response", false)
            }
            "initialized" -> {
                validateTargets(initialized.artifacts, payload)
                payload.artifacts.forEach { artifact ->
                    checkCancellation()
                    val target = initialized.artifacts.first { it.id == artifact.manifest.id }
                    put(artifact.bytes, target)
                }
            }
            else -> throw CrumbUploadFailure("init.terminal_state", false)
        }

        sendLifecycle(
            components = listOf("sdk", "v1", "reports", reportId, "complete"),
            reportId = reportId,
            operation = "complete",
            body = EMPTY_OPERATION_BODY,
        )
    }

    private fun sendLifecycle(
        components: List<String>,
        reportId: String,
        operation: String,
        body: ByteArray?,
    ): CrumbUploadHttpResponse {
        val headers = linkedMapOf(
            "Authorization" to "Bearer ${settings.projectKey}",
            "Idempotency-Key" to "$reportId:$operation",
        )
        if (body != null) headers["Content-Type"] = "application/json"
        val response = send(
            CrumbUploadHttpRequest(
                url = endpoint(components),
                method = "POST",
                headers = headers,
                body = body,
                timeoutMillis = 15_000,
            ),
            operation,
        )
        if (response.statusCode !in 200..299) throw httpFailure(operation, response.statusCode)
        return response
    }

    private fun put(bytes: ByteArray, target: InitializationArtifact) {
        if (target.method != "PUT" || !validUploadUrl(target.url)) {
            throw CrumbUploadFailure("artifact.invalid_target", false)
        }
        val response = send(
            CrumbUploadHttpRequest(
                url = target.url,
                method = "PUT",
                headers = target.headers.filterKeys(::validHeaderName),
                body = bytes,
                timeoutMillis = 60_000,
            ),
            "artifact",
        )
        if (response.statusCode !in 200..299) throw httpFailure("artifact", response.statusCode)
    }

    private fun send(request: CrumbUploadHttpRequest, operation: String): CrumbUploadHttpResponse {
        checkCancellation()
        return try {
            transport.send(request).also { checkCancellation() }
        } catch (_: CancellationException) {
            throw CancellationException()
        } catch (_: Exception) {
            checkCancellation()
            throw CrumbUploadFailure("$operation.network", true)
        }
    }

    private fun decodeInitialization(bytes: ByteArray, reportId: String): InitializationResponse {
        try {
            val root = JSONObject(String(bytes, Charsets.UTF_8))
            if (root.getString("report_id") != reportId) {
                throw CrumbUploadFailure("init.invalid_response", false)
            }
            val artifacts = root.getJSONArray("artifacts")
            return InitializationResponse(
                reportId = reportId,
                status = root.getString("status"),
                artifacts = (0 until artifacts.length()).map { index ->
                    val value = artifacts.getJSONObject(index)
                    val headerObject = value.getJSONObject("headers")
                    val headers = headerObject.keys().asSequence().associateWith(headerObject::getString)
                    InitializationArtifact(
                        id = value.getString("id"),
                        uploadId = value.getString("upload_id"),
                        method = value.getString("method"),
                        url = value.getString("url"),
                        headers = headers,
                    )
                },
            )
        } catch (failure: CrumbUploadFailure) {
            throw failure
        } catch (_: Exception) {
            throw CrumbUploadFailure("init.invalid_response", false)
        }
    }

    private fun validateTargets(
        targets: List<InitializationArtifact>,
        payload: CrumbQueuedReportPayload,
    ) {
        val targetsById = targets.associateBy(InitializationArtifact::id)
        if (
            targetsById.size != targets.size ||
            targetsById.keys != payload.artifacts.map { it.manifest.id }.toSet() ||
            payload.artifacts.any { artifact ->
                targetsById[artifact.manifest.id]?.uploadId != artifact.manifest.uploadId
            }
        ) {
            throw CrumbUploadFailure("init.invalid_response", false)
        }
    }

    private fun wrapEnvelope(envelope: ByteArray): ByteArray =
        "{\"envelope\":".toByteArray() + envelope + "}".toByteArray()

    private fun endpoint(components: List<String>): String =
        settings.ingestionUrl.trimEnd('/') + "/" + components.joinToString("/")

    private fun validUploadUrl(value: String): Boolean {
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase()
        val baseScheme = URI(settings.ingestionUrl).scheme.lowercase()
        return uri.isAbsolute && !uri.host.isNullOrBlank() && uri.userInfo == null &&
            uri.fragment == null && (scheme == "https" || (scheme == "http" && baseScheme == "http"))
    }

    private fun validHeaderName(value: String): Boolean =
        value.isNotEmpty() && value.all { it in HEADER_CHARACTERS }

    private fun httpFailure(operation: String, statusCode: Int): CrumbUploadFailure {
        val retryable = statusCode in setOf(408, 425, 429) || statusCode in 500..599 ||
            (operation == "artifact" && statusCode == 403)
        return CrumbUploadFailure("$operation.http_$statusCode", retryable)
    }

    private fun checkCancellation() {
        if (cancelled.get() || Thread.currentThread().isInterrupted) throw CancellationException()
    }

    companion object {
        private val EMPTY_OPERATION_BODY = "{}".toByteArray()

        private const val HEADER_CHARACTERS =
            "!#\$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

        @JvmSynthetic
        fun create(
            queue: CrumbReportQueue,
            settings: CrumbUploadSettings,
        ): CrumbReportUploadWorker = CrumbReportUploadWorker(
            queue,
            settings,
            CrumbHttpUrlConnectionUploadTransport(),
        )
    }
}

private class CrumbHttpUrlConnectionUploadTransport : CrumbUploadTransport {
    @Volatile
    private var activeConnection: HttpURLConnection? = null

    override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse {
        val connection = URL(request.url).openConnection() as HttpURLConnection
        activeConnection = connection
        try {
            connection.requestMethod = request.method
            connection.connectTimeout = request.timeoutMillis
            connection.readTimeout = request.timeoutMillis
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            request.headers.forEach(connection::setRequestProperty)
            request.body?.let { body ->
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val statusCode = connection.responseCode
            val input = if (statusCode >= 400) connection.errorStream else connection.inputStream
            return CrumbUploadHttpResponse(statusCode, input.readBounded())
        } finally {
            activeConnection = null
            connection.disconnect()
        }
    }

    override fun cancel() {
        activeConnection?.disconnect()
    }
}

private fun InputStream?.readBounded(maximumBytes: Int = 1_048_576): ByteArray {
    if (this == null) return ByteArray(0)
    use { stream ->
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8_192)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            if (output.size() + count > maximumBytes) throw IOException("upload response exceeded limit")
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }
}

private data class InitializationResponse(
    val reportId: String,
    val status: String,
    val artifacts: List<InitializationArtifact>,
)

private data class InitializationArtifact(
    val id: String,
    val uploadId: String,
    val method: String,
    val url: String,
    val headers: Map<String, String>,
)

private class CrumbUploadFailure(
    val reason: String,
    val retryable: Boolean,
) : IllegalStateException(reason)
