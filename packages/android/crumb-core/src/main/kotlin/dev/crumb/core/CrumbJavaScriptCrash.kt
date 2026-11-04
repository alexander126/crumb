package dev.crumb.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.util.Locale
import java.util.UUID

data class CrumbJavaScriptCrashRelease(
    val appVersion: String?,
    val nativeBuild: String?,
    val bundleVersion: String?,
)

data class CrumbJavaScriptBreadcrumb(
    val timestamp: Instant,
    val source: String,
    val category: String,
    val message: String,
)

data class CrumbJavaScriptCrash(
    val recordId: String,
    val fingerprint: String,
    val source: String,
    val kind: String,
    val type: String,
    val message: String,
    val stack: String?,
    val occurredAt: Instant,
    val release: CrumbJavaScriptCrashRelease,
    val breadcrumbs: List<CrumbJavaScriptBreadcrumb>,
    val context: Map<String, String>,
    val isFatal: Boolean,
    val nativeTerminationWrapperObserved: Boolean,
) {
    /** Carries failure-time metadata from the handoff store to its recovery. */
    @CrumbInternalApi
    @JvmSynthetic
    var failureContext: CrumbJavaScriptFailureContext? = null
}

