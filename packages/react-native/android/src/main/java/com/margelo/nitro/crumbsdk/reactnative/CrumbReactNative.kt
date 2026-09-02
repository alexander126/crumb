package com.margelo.nitro.crumbsdk.reactnative

import android.app.Application
import android.os.Build
import com.facebook.react.bridge.UiThreadUtil
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbDiagnosticsOptions
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbLogEntry
import dev.crumb.core.CrumbLogLevel
import dev.crumb.core.CrumbLogOptions
import dev.crumb.core.CrumbLogProvider
import dev.crumb.core.CrumbReporterField
import dev.crumb.core.CrumbReporterOptions
import dev.crumb.core.CrumbPrivacyOptions
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbTheme
import dev.crumb.core.CrumbUploadOptions
import dev.crumb.core.CrumbApplicationMetadata
import dev.crumb.core.CrumbCustomContextOptions
import dev.crumb.core.CrumbWorkspacePolicyOptions
import dev.crumb.ui.CrumbReporter
import org.json.JSONObject

class CrumbReactNative : HybridCrumbReactNativeSpec() {
    private val logBuffer = ReactNativeLogBuffer()
    @Volatile
    private var javascriptCrashCaptureEnabled = false

    override fun start(configurationJson: String) {
        val context = requireNotNull(NitroModules.applicationContext) {
            "React Native is not ready. Call Crumb.start after the app has mounted."
        }
        val payload = JSONObject(configurationJson)
        val release = payload.optJSONObject("release") ?: JSONObject()
        val diagnostics = payload.optJSONObject("diagnostics")
        val logs = diagnostics?.optJSONObject("logs")
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val nativeBuild = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode.toString()
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toString()
        }
        val maximumEntries = logs?.optionalInt("maximumEntries") ?: 200
        val maximumBytes = logs?.optionalInt("maximumBytes") ?: 65_536
        val lookbackMillis = logs?.optionalLong("lookbackMs") ?: 60_000L

        logBuffer.configure(
            lookbackMillis = lookbackMillis,
            maximumEntries = maximumEntries,
            maximumBytes = maximumBytes,
        )

        Crumb.start(
            CrumbConfiguration(
                projectKey = payload.getString("projectKey"),
                environment = payload.getString("environment"),
                release = CrumbRelease(
                    appVersion = release.optionalString("appVersion")
                        ?: packageInfo.versionName
                        ?: "0",
                    nativeBuild = release.optionalString("nativeBuild") ?: nativeBuild,
                    bundleVersion = release.optionalString("bundleVersion"),
                ),
                invocation = payload.invocations(),
                capture = payload.captureOptions(),
                diagnostics = CrumbDiagnosticsOptions(
                    healthCheckUrl = diagnostics?.optionalString("healthCheckUrl"),
                    timeoutMillis = diagnostics?.optionalLong("timeoutMs") ?: 2_000,
                    logs = CrumbLogOptions(
                        enabled = logs?.optionalBoolean("enabled") ?: true,
                        lookbackMillis = lookbackMillis,
                        maximumEntries = maximumEntries,
                        maximumBytes = maximumBytes,
                        provider = logBuffer,
                    ),
                ),
                privacy = payload.privacyOptions(),
                upload = CrumbUploadOptions(
                    ingestionUrl = payload.optJSONObject("upload")
                        ?.optionalString("ingestionUrl"),
                ),
                reporter = payload.reporterOptions(),
                evidence = payload.evidenceOptions(),
                application = payload.applicationMetadata(),
                customContext = payload.customContextOptions(),
                workspacePolicy = payload.workspacePolicyOptions(),
            ),
        )
        javascriptCrashCaptureEnabled = payload.optJSONObject("javascriptCrashCapture")
            ?.optionalBoolean("enabled") == true
    }

    override fun canCollectLogs(): Boolean = Crumb.canCollectLogs()

    override fun installReporter(): Promise<Boolean> {
        val promise = Promise<Boolean>()
        val context = runCatching {
            requireNotNull(NitroModules.applicationContext).applicationContext
        }.getOrElse {
            promise.reject(it)
            return promise
        }
        val shouldRecoverJavaScriptCrashes = javascriptCrashCaptureEnabled
        Thread({
            if (shouldRecoverJavaScriptCrashes) {
                runCatching { Crumb.recoverPendingJavaScriptCrashes(context) }
            }
            UiThreadUtil.runOnUiThread {
                runCatching {
                    CrumbReporter.install(context as Application)
                }.onSuccess(promise::resolve)
                    .onFailure(promise::reject)
            }
        }, "Crumb JavaScript crash recovery").start()
        return promise
    }

    override fun show(): Promise<Boolean> {
        val promise = Promise<Boolean>()
        UiThreadUtil.runOnUiThread {
            runCatching {
                val context = requireNotNull(NitroModules.applicationContext)
                val activity = context.getCurrentActivity() ?: return@runCatching false
                CrumbReporter.show(activity)
            }.onSuccess(promise::resolve)
                .onFailure(promise::reject)
        }
        return promise
    }

    override fun recordJavaScriptCrash(payloadJson: String) {
        if (!javascriptCrashCaptureEnabled) return
        val context = requireNotNull(NitroModules.applicationContext)
        val payload = JSONObject(payloadJson)
        Crumb.recordJavaScriptCrash(context, payload.javascriptCrash())
    }

    override fun addLog(entryJson: String) {
        if (!Crumb.canCollectLogs()) return
        val payload = JSONObject(entryJson)
        logBuffer.append(
            CrumbLogEntry(
                timestampMillis = payload.getLong("timestampMs"),
                level = payload.getString("level").toNativeLogLevel(),
                source = payload.optString("source", "react-native"),
                category = payload.optString("category", "javascript"),
                message = payload.getString("message"),
            ),
        )
    }

    override fun clearLogs() {
        logBuffer.clear()
    }
}

private fun JSONObject.invocations(): Set<CrumbInvocation> {
    val values = optJSONArray("invocation")
        ?: return setOf(CrumbInvocation.SHAKE, CrumbInvocation.PROGRAMMATIC)
    return buildSet {
        for (index in 0 until values.length()) {
            when (values.getString(index)) {
                "shake" -> add(CrumbInvocation.SHAKE)
                "programmatic" -> add(CrumbInvocation.PROGRAMMATIC)
            }
        }
    }
}

private fun JSONObject.captureOptions(): CrumbCaptureOptions {
    val capture = optJSONObject("capture") ?: return CrumbCaptureOptions()
    return CrumbCaptureOptions(
        screenshot = capture.optionalBoolean("screenshot") ?: true,
        maximumScreenshotDimension = capture.optionalInt("maximumScreenshotDimension") ?: 2_048,
        maximumScreenshotBytes = capture.optionalInt("maximumScreenshotBytes") ?: 5_242_880,
    )
}

private fun JSONObject.privacyOptions(): CrumbPrivacyOptions {
    val privacy = optJSONObject("privacy") ?: return CrumbPrivacyOptions()
    return CrumbPrivacyOptions(
        maskAllTextInputs = privacy.optionalBoolean("maskAllTextInputs") ?: true,
        maskScreenshotsBeforeUpload = privacy.optionalBoolean("maskScreenshotsBeforeUpload") ?: true,
    )
}

private fun JSONObject.reporterOptions(): CrumbReporterOptions {
    val reporter = optJSONObject("reporter") ?: return CrumbReporterOptions()
    val theme = when (reporter.optionalString("theme") ?: "system") {
        "system" -> CrumbTheme.SYSTEM
        "light" -> CrumbTheme.LIGHT
        "dark" -> CrumbTheme.DARK
        else -> error("reporter.theme is unsupported")
    }
    val fields = reporter.optJSONArray("visibleFields")?.let { array ->
        buildSet {
            for (index in 0 until array.length()) {
                when (array.getString(index)) {
                    "category" -> add(CrumbReporterField.CATEGORY)
                    "description" -> add(CrumbReporterField.DESCRIPTION)
                    else -> error("reporter.visibleFields contains an unsupported value")
                }
            }
        }
    } ?: CrumbReporterOptions().visibleFields
    return CrumbReporterOptions(theme = theme, visibleFields = fields)
}

private fun JSONObject.evidenceOptions(): Set<CrumbEvidenceCategory> {
    val evidence = optJSONArray("evidence") ?: return CrumbEvidenceCategory.entries.toSet()
    return buildSet {
        for (index in 0 until evidence.length()) {
            when (evidence.getString(index)) {
                "screenshot" -> add(CrumbEvidenceCategory.SCREENSHOT)
                "performance" -> add(CrumbEvidenceCategory.PERFORMANCE)
                "network" -> add(CrumbEvidenceCategory.NETWORK)
                "logs" -> add(CrumbEvidenceCategory.LOGS)
                "thread_stacks" -> add(CrumbEvidenceCategory.THREAD_STACKS)
                "health_check" -> add(CrumbEvidenceCategory.HEALTH_CHECK)
                "custom_context" -> add(CrumbEvidenceCategory.CUSTOM_CONTEXT)
                else -> error("evidence contains an unsupported value")
            }
        }
    }
}

private fun JSONObject.applicationMetadata(): CrumbApplicationMetadata {
    val application = optJSONObject("application") ?: return CrumbApplicationMetadata()
    return CrumbApplicationMetadata(name = application.optionalString("name"))
}

private fun JSONObject.customContextOptions(): CrumbCustomContextOptions {
    val customContext = optJSONObject("customContext") ?: return CrumbCustomContextOptions()
    val values = customContext.optJSONObject("values")?.let { valuesObject ->
        buildMap {
            val names = valuesObject.keys()
            while (names.hasNext()) {
                val name = names.next()
                put(name, valuesObject.getString(name))
            }
        }
    } ?: emptyMap()
    val allowedKeys = customContext.optJSONArray("allowedKeys")?.let { array ->
        buildSet {
            for (index in 0 until array.length()) add(array.getString(index))
        }
    } ?: emptySet()
    return CrumbCustomContextOptions(values = values, allowedKeys = allowedKeys)
}

private fun JSONObject.workspacePolicyOptions(): CrumbWorkspacePolicyOptions {
    val policy = optJSONObject("workspacePolicy") ?: return CrumbWorkspacePolicyOptions()
    return CrumbWorkspacePolicyOptions(
        url = policy.optionalString("url"),
        timeoutMillis = policy.optionalLong("timeoutMs") ?: 2_000,
    )
}

private fun JSONObject.javascriptCrash(): dev.crumb.core.CrumbJavaScriptCrash {
    val kind = when (getString("kind")) {
        "fatal_exception" -> dev.crumb.core.CrumbJavaScriptCrashKind.FATAL_EXCEPTION
        "unhandled_rejection" -> dev.crumb.core.CrumbJavaScriptCrashKind.UNHANDLED_REJECTION
        else -> error("javascript crash kind is unsupported")
    }
    val source = when (optionalString("source") ?: "javascript") {
        "javascript" -> dev.crumb.core.CrumbJavaScriptCrashSource.JAVASCRIPT
        "native_termination_wrapper" ->
            dev.crumb.core.CrumbJavaScriptCrashSource.NATIVE_TERMINATION_WRAPPER
        else -> error("javascript crash source is unsupported")
    }
    val breadcrumbs = optJSONArray("breadcrumbs")?.let { array ->
        buildList {
            for (index in 0 until array.length()) {
                val breadcrumb = array.optJSONObject(index) ?: continue
                add(
                    dev.crumb.core.CrumbJavaScriptBreadcrumb(
                        timestampMillis = breadcrumb.optLong("timestampMs", System.currentTimeMillis()),
                        category = breadcrumb.optString("category", "javascript"),
                        message = breadcrumb.optString("message", ""),
                    ),
                )
            }
        }
    } ?: emptyList()
    return dev.crumb.core.CrumbJavaScriptCrash(
        kind = kind,
        source = source,
        errorType = getString("errorType"),
        message = getString("message"),
        rawStack = optionalString("rawStack"),
        fingerprint = optionalString("fingerprint"),
        occurredAtMillis = optLong("occurredAtMs", System.currentTimeMillis()),
        nativeTerminationWrapper = optBoolean("nativeTerminationWrapper", false),
        breadcrumbs = breadcrumbs,
    )
}

private fun JSONObject.optionalString(name: String): String? =
    if (has(name) && !isNull(name)) getString(name) else null

private fun JSONObject.optionalBoolean(name: String): Boolean? =
    if (has(name) && !isNull(name)) getBoolean(name) else null

private fun JSONObject.optionalInt(name: String): Int? =
    if (has(name) && !isNull(name)) getInt(name) else null

private fun JSONObject.optionalLong(name: String): Long? =
    if (has(name) && !isNull(name)) getLong(name) else null

private fun String.toNativeLogLevel(): CrumbLogLevel = when (this) {
    "debug" -> CrumbLogLevel.DEBUG
    "info" -> CrumbLogLevel.INFO
    "notice" -> CrumbLogLevel.NOTICE
    "warning" -> CrumbLogLevel.WARNING
    "error" -> CrumbLogLevel.ERROR
    "fault" -> CrumbLogLevel.FAULT
    else -> CrumbLogLevel.INFO
}

private class ReactNativeLogBuffer : CrumbLogProvider {
    private val lock = Any()
    private val entries = ArrayDeque<CrumbLogEntry>()
    private var lookbackMillis = 60_000L
    private var maximumEntries = 200
    private var maximumBytes = 65_536

    fun configure(
        lookbackMillis: Long,
        maximumEntries: Int,
        maximumBytes: Int,
    ) = synchronized(lock) {
        this.lookbackMillis = lookbackMillis
        this.maximumEntries = maximumEntries
        this.maximumBytes = maximumBytes
        prune(System.currentTimeMillis())
    }

    fun append(entry: CrumbLogEntry) = synchronized(lock) {
        entries.addLast(entry)
        prune(System.currentTimeMillis())
    }

    fun clear() = synchronized(lock) {
        entries.clear()
    }

    override fun recentLogs(): List<CrumbLogEntry> = synchronized(lock) {
        prune(System.currentTimeMillis())
        entries.toList()
    }

    private fun prune(now: Long) {
        val earliest = now - lookbackMillis
        while (entries.firstOrNull()?.timestampMillis?.let { it < earliest } == true) {
            entries.removeFirst()
        }
        while (entries.size > maximumEntries || byteCount() > maximumBytes) {
            entries.removeFirstOrNull()
        }
    }

    private fun byteCount(): Int = entries.sumOf { entry ->
        entry.source.toByteArray().size +
            entry.category.toByteArray().size +
            entry.message.toByteArray().size +
            32
    }
}
