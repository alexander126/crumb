package dev.crumb.ui

import android.app.Application
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbPolicyCache
import dev.crumb.core.CrumbPolicySource
import dev.crumb.core.CrumbWorkspacePolicy
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/** Fetches optional workspace policy without delaying reporter presentation. */
internal object CrumbWorkspacePolicyCoordinator {
    private const val preferencesName = "crumb.workspace-policy"
    private const val maximumResponseBytes = CrumbPolicyCache.maximumBytes

    private var application: Application? = null
    private var fetching = false

    @Synchronized
    fun install(application: Application) {
        if (this.application != null) return
        this.application = application
        loadCachedPolicy(application)
        refresh()
    }

    @Synchronized
    fun refresh() {
        val app = application ?: return
        val settings = runCatching { Crumb.workspacePolicyFetchSettings() }.getOrNull() ?: return
        if (fetching) return
        fetching = true
        Crumb.beginWorkspacePolicyFetch()
        Thread({
            val policy = runCatching { fetch(settings.url, settings.projectKey, settings.timeoutMillis) }
                .getOrNull()
            if (policy != null) {
                val accepted = Crumb.applyWorkspacePolicy(policy, CrumbPolicySource.FRESH)
                val key = runCatching { Crumb.workspacePolicyCacheKey() }.getOrNull()
                if (accepted && key != null) {
                    app.getSharedPreferences(preferencesName, Application.MODE_PRIVATE)
                        .edit()
                        .putString(key, policyJson(policy))
                        .apply()
                }
            } else {
                Crumb.markWorkspacePolicyUnavailable()
            }
            synchronized(this) { fetching = false }
        }, "Crumb workspace policy").start()
    }

    private fun loadCachedPolicy(application: Application) {
        val key = runCatching { Crumb.workspacePolicyCacheKey() }.getOrNull() ?: return
        val raw = application.getSharedPreferences(preferencesName, Application.MODE_PRIVATE)
            .getString(key, null)
        val policy = CrumbPolicyCache.load(raw) ?: return
        Crumb.applyWorkspacePolicy(policy, CrumbPolicySource.CACHED)
    }

    private fun fetch(urlValue: String, projectKey: String, timeoutMillis: Long): CrumbWorkspacePolicy {
        val connection = (URL(urlValue).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = timeoutMillis.toInt()
            readTimeout = timeoutMillis.toInt()
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Authorization", "Bearer $projectKey")
        }
        return connection.useConnection {
            if (responseCode !in 200..299) error("workspace policy request failed")
            val body = inputStream.use { stream ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4_096)
                var total = 0
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > maximumResponseBytes) error("workspace policy response is too large")
                    output.write(buffer, 0, count)
                }
                output.toString(StandardCharsets.UTF_8.name())
            }
            CrumbWorkspacePolicy.fromJson(body)
        }
    }

    private fun policyJson(policy: CrumbWorkspacePolicy): String = buildString {
        append('{')
        append("\"schema_version\":\"1.0\",")
        append("\"version\":").append(policy.version).append(',')
        append("\"expires_at\":\"").append(java.time.Instant.ofEpochMilli(policy.expiresAtMillis)).append("\",")
        append("\"disabled_evidence\":")
        append(policy.disabledEvidence.map { "\"${it.wireValue()}\"" }.joinToString(prefix = "[", postfix = "]"))
        append(',')
        append("\"hidden_reporter_fields\":")
        append(policy.hiddenReporterFields.map { "\"${it.wireValue()}\"" }.joinToString(prefix = "[", postfix = "]"))
        append(',')
        append("\"allowed_context_keys\":")
        append(policy.allowedContextKeys.map { "\"${it.replace("\\", "\\\\").replace("\"", "\\\"")}\"" }
            .joinToString(prefix = "[", postfix = "]"))
        append('}')
    }

    private fun <T> HttpURLConnection.useConnection(block: HttpURLConnection.() -> T): T = try {
        block()
    } finally {
        disconnect()
    }
}

private fun dev.crumb.core.CrumbEvidenceCategory.wireValue(): String = when (this) {
    dev.crumb.core.CrumbEvidenceCategory.SCREENSHOT -> "screenshot"
    dev.crumb.core.CrumbEvidenceCategory.PERFORMANCE -> "performance"
    dev.crumb.core.CrumbEvidenceCategory.NETWORK -> "network"
    dev.crumb.core.CrumbEvidenceCategory.LOGS -> "logs"
    dev.crumb.core.CrumbEvidenceCategory.THREAD_STACKS -> "thread_stacks"
    dev.crumb.core.CrumbEvidenceCategory.HEALTH_CHECK -> "health_check"
    dev.crumb.core.CrumbEvidenceCategory.CUSTOM_CONTEXT -> "custom_context"
}

private fun dev.crumb.core.CrumbReporterField.wireValue(): String = when (this) {
    dev.crumb.core.CrumbReporterField.CATEGORY -> "category"
    dev.crumb.core.CrumbReporterField.DESCRIPTION -> "description"
}
