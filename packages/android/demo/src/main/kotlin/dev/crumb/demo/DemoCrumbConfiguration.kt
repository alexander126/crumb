package dev.crumb.demo

import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbDiagnosticsOptions
import dev.crumb.core.CrumbLogOptions
import dev.crumb.core.CrumbLogProvider
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbUploadOptions

internal data class DemoCrumbConfiguration(
    val crumb: CrumbConfiguration,
    val modeDescription: String,
) {
    companion object {
        fun make(
            projectKey: String = BuildConfig.CRUMB_DOGFOOD_PROJECT_KEY,
            ingestionUrl: String = BuildConfig.CRUMB_DOGFOOD_INGESTION_URL,
            environment: String = BuildConfig.CRUMB_DOGFOOD_ENVIRONMENT,
            logProvider: CrumbLogProvider? = null,
            appVersion: String = BuildConfig.VERSION_NAME,
            nativeBuild: String = BuildConfig.VERSION_CODE.toString(),
        ): DemoCrumbConfiguration {
            val resolvedKey = projectKey.trim().takeIf(String::isNotEmpty)
            val resolvedUrl = ingestionUrl.trim().trimEnd('/').takeIf(::isHttpUrl)
            val uploadEnabled = resolvedKey != null && resolvedUrl != null

            return DemoCrumbConfiguration(
                crumb = CrumbConfiguration(
                    projectKey = if (uploadEnabled) checkNotNull(resolvedKey) else "poc_write_key",
                    environment = if (uploadEnabled) environment.trim().ifEmpty { "staging" } else "local",
                    release = CrumbRelease(appVersion = appVersion, nativeBuild = nativeBuild),
                    diagnostics = CrumbDiagnosticsOptions(
                        healthCheckUrl = resolvedUrl?.let { "$it/health" }.takeIf { uploadEnabled },
                        logs = CrumbLogOptions(provider = logProvider),
                    ),
                    upload = CrumbUploadOptions(
                        ingestionUrl = resolvedUrl.takeIf { uploadEnabled },
                    ),
                ),
                modeDescription = if (uploadEnabled) "Staging upload enabled" else "Local-only mode",
            )
        }

        private fun isHttpUrl(value: String): Boolean = runCatching {
            val url = java.net.URI(value)
            (url.scheme == "https" || url.scheme == "http") && !url.host.isNullOrBlank()
        }.getOrDefault(false)
    }
}
