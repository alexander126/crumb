package dev.crumb.ui

import android.os.SystemClock
import dev.crumb.core.CrumbHealthCheckDiagnostic
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLException

internal data class CrumbHealthHeadResult(
    val statusCode: Int?,
    val latencyMilliseconds: Long,
    val failure: String?,
)

internal object CrumbInfrastructureHealthProbe {
    fun capture(
        value: String,
        timeoutMillis: Long,
        head: (URL, Long) -> CrumbHealthHeadResult = ::performHead,
    ): CrumbHealthCheckDiagnostic {
        val url = runCatching { URL(value) }.getOrNull()
        if (url == null) {
            return CrumbHealthCheckDiagnostic(
                host = "invalid",
                succeeded = false,
                statusCode = null,
                latencyMilliseconds = 0,
                failure = "invalid_url",
            )
        }
        val result = runCatching { head(url, timeoutMillis) }.getOrElse { error ->
            CrumbHealthHeadResult(
                statusCode = null,
                latencyMilliseconds = 0,
                failure = failureName(error),
            )
        }
        return CrumbHealthCheckDiagnostic(
            host = url.host.ifBlank { "unknown" },
            succeeded = result.failure == null &&
                result.statusCode?.let { it in 200..299 } == true,
            statusCode = result.statusCode,
            latencyMilliseconds = result.latencyMilliseconds.coerceIn(0, 30_000),
            failure = result.failure?.take(128),
        )
    }

    private fun performHead(url: URL, timeoutMillis: Long): CrumbHealthHeadResult {
        val startedAt = SystemClock.elapsedRealtime()
        val result = AtomicReference<CrumbHealthHeadResult?>()
        val connection = AtomicReference<HttpURLConnection?>()
        val completed = CountDownLatch(1)
        val worker = Thread({
            try {
                val active = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "HEAD"
                    connectTimeout = timeoutMillis.toInt()
                    readTimeout = timeoutMillis.toInt()
                    useCaches = false
                    instanceFollowRedirects = true
                }
                connection.set(active)
                result.set(
                    CrumbHealthHeadResult(
                        statusCode = active.responseCode,
                        latencyMilliseconds = SystemClock.elapsedRealtime() - startedAt,
                        failure = null,
                    ),
                )
            } catch (error: Exception) {
                result.set(
                    CrumbHealthHeadResult(
                        statusCode = null,
                        latencyMilliseconds = SystemClock.elapsedRealtime() - startedAt,
                        failure = failureName(error),
                    ),
                )
            } finally {
                connection.get()?.disconnect()
                completed.countDown()
            }
        }, "Crumb health request").apply {
            isDaemon = true
            start()
        }

        val finished = try {
            completed.await(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            connection.get()?.disconnect()
            worker.interrupt()
            Thread.currentThread().interrupt()
            return CrumbHealthHeadResult(
                statusCode = null,
                latencyMilliseconds = SystemClock.elapsedRealtime() - startedAt,
                failure = "cancelled",
            )
        }
        if (!finished) {
            connection.get()?.disconnect()
            worker.interrupt()
            return CrumbHealthHeadResult(
                statusCode = null,
                latencyMilliseconds = timeoutMillis,
                failure = "timeout",
            )
        }
        return result.get() ?: CrumbHealthHeadResult(
            statusCode = null,
            latencyMilliseconds = SystemClock.elapsedRealtime() - startedAt,
            failure = "unavailable",
        )
    }

    private fun failureName(error: Throwable): String = when (error) {
        is SocketTimeoutException -> "timeout"
        is UnknownHostException -> "cannot_find_host"
        is ConnectException -> "cannot_connect"
        is SSLException -> "tls_failed"
        else -> error.javaClass.simpleName.ifBlank { "transport_error" }.take(128)
    }
}
