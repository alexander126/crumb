package dev.crumb.core

import android.content.Context
import android.os.Build
import android.os.Process
import java.util.Locale
import java.util.TimeZone

data class CrumbConfiguration(
    val projectKey: String,
    val environment: String,
    val release: CrumbRelease,
    val invocation: Set<CrumbInvocation> = setOf(CrumbInvocation.SHAKE, CrumbInvocation.PROGRAMMATIC),
    val capture: CrumbCaptureOptions = CrumbCaptureOptions(),
    val diagnostics: CrumbDiagnosticsOptions = CrumbDiagnosticsOptions(),
    val privacy: CrumbPrivacyOptions = CrumbPrivacyOptions(),
    val upload: CrumbUploadOptions = CrumbUploadOptions(),
    val reporter: CrumbReporterOptions = CrumbReporterOptions(),
    val evidence: Set<CrumbEvidenceCategory> = CrumbEvidenceCategory.entries.toSet(),
    val application: CrumbApplicationMetadata = CrumbApplicationMetadata(),
    val customContext: CrumbCustomContextOptions = CrumbCustomContextOptions(),
    val workspacePolicy: CrumbWorkspacePolicyOptions = CrumbWorkspacePolicyOptions(),
)

data class CrumbRelease(
    val appVersion: String,
    val nativeBuild: String,
    val bundleVersion: String? = null,
)

enum class CrumbInvocation { SHAKE, PROGRAMMATIC }

data class CrumbCaptureOptions(
    val screenshot: Boolean = true,
    val maximumScreenshotDimension: Int = 2_048,
    val maximumScreenshotBytes: Int = 5_242_880,
)

data class CrumbDiagnosticsOptions(
    /** Optional public Crumb `/health` URL. Null disables API probing. */
    val healthCheckUrl: String? = null,
    val timeoutMillis: Long = 2_000,
    val logs: CrumbLogOptions = CrumbLogOptions(),
)

enum class CrumbLogLevel { DEBUG, INFO, NOTICE, WARNING, ERROR, FAULT }

data class CrumbLogEntry(
    val timestampMillis: Long,
    val level: CrumbLogLevel,
    val source: String = "application",
    val category: String,
    val message: String,
)

/** Supplies a prompt in-memory snapshot of application logs when a report is opened. */
fun interface CrumbLogProvider {
    fun recentLogs(): List<CrumbLogEntry>
}

data class CrumbLogOptions(
    val enabled: Boolean = true,
    val lookbackMillis: Long = 60_000,
    val maximumEntries: Int = 200,
    val maximumBytes: Int = 65_536,
    val provider: CrumbLogProvider? = null,
)

enum class CrumbLogCaptureStatus { CAPTURED, EMPTY, UNAVAILABLE, DISABLED, DISABLED_BY_POLICY }

enum class CrumbTheme { SYSTEM, LIGHT, DARK }

enum class CrumbReporterField { CATEGORY, DESCRIPTION }

enum class CrumbEvidenceCategory {
    SCREENSHOT,
    PERFORMANCE,
    NETWORK,
    LOGS,
    THREAD_STACKS,
    HEALTH_CHECK,
    CUSTOM_CONTEXT,
}

data class CrumbReporterOptions(
    val theme: CrumbTheme = CrumbTheme.SYSTEM,
    val visibleFields: Set<CrumbReporterField> = setOf(
        CrumbReporterField.CATEGORY,
        CrumbReporterField.DESCRIPTION,
    ),
)

data class CrumbApplicationMetadata(
    val name: String? = null,
)

data class CrumbCustomContextOptions(
    val values: Map<String, String> = emptyMap(),
    val allowedKeys: Set<String> = emptySet(),
)

data class CrumbWorkspacePolicyOptions(
    val url: String? = null,
    val timeoutMillis: Long = 2_000,
)

data class CrumbLogDiagnostic(
    val status: CrumbLogCaptureStatus,
    val sources: List<String>,
    val entries: List<CrumbLogEntry>,
    val truncated: Boolean,
    val droppedEntryCount: Int,
    val failures: List<String>,
)

data class CrumbPrivacyOptions(
    val maskAllTextInputs: Boolean = true,
    val maskScreenshotsBeforeUpload: Boolean = true,
)

data class CrumbUploadOptions(
    /** Base URL for the Crumb ingestion service. Null keeps network upload disabled. */
    val ingestionUrl: String? = null,
)

data class CrumbThreadDiagnostic(
    val id: Long,
    val name: String,
    val state: String,
    val cpuUsagePercent: Double?,
)

enum class CrumbStackTraceCaptureStatus { CAPTURED, UNAVAILABLE }

data class CrumbThreadStackDiagnostic(
    val id: Long,
    val name: String,
    val state: String,
    val frames: List<String>,
)

data class CrumbStackTraceDiagnostic(
    val status: CrumbStackTraceCaptureStatus,
    val scope: String,
    val threads: List<CrumbThreadStackDiagnostic>,
    val truncated: Boolean,
    val unavailableReason: String?,
)

data class CrumbHealthCheckDiagnostic(
    val host: String,
    val succeeded: Boolean,
    val statusCode: Int?,
    val latencyMilliseconds: Long,
    val failure: String?,
)

data class CrumbNetworkDiagnostic(
    val status: String,
    val transport: String,
    val cellularGeneration: String?,
    val isExpensive: Boolean,
    val isConstrained: Boolean,
    val healthCheck: CrumbHealthCheckDiagnostic?,
)

data class CrumbDiagnosticsSnapshot(
    val capturedAtMillis: Long,
    val location: String,
    val processName: String,
    val processId: Int,
    val cpuUsagePercent: Double?,
    val residentMemoryBytes: Long?,
    val physicalFootprintBytes: Long?,
    val thermalState: String,
    val threadCount: Int,
    val busiestThreads: List<CrumbThreadDiagnostic>,
    val gpuStatus: String,
    val network: CrumbNetworkDiagnostic,
    val logs: CrumbLogDiagnostic,
    val stackTraces: CrumbStackTraceDiagnostic,
)

class CrumbReportSettings internal constructor(
    val environment: String,
    val release: CrumbRelease,
    val invocation: Set<CrumbInvocation>,
    val capture: CrumbCaptureOptions,
    val diagnostics: CrumbDiagnosticsOptions,
    val privacy: CrumbPrivacyOptions,
    val reporter: CrumbReporterOptions,
    val evidence: Set<CrumbEvidenceCategory>,
    val application: CrumbApplicationMetadata,
    val customContext: Map<String, String>,
    val policyStatus: CrumbPolicyStatus,
    val workspacePolicyVersion: Int?,
)

class CrumbUploadSettings internal constructor(
    val projectKey: String,
    val ingestionUrl: String,
)

sealed class CrumbStartException(message: String) : IllegalArgumentException(message) {
    class EmptyProjectKey : CrumbStartException("projectKey must not be empty")
    class InvalidProjectKey :
        CrumbStartException("projectKey must be at most 512 printable characters")
    class EmptyEnvironment : CrumbStartException("environment must not be empty")
    class InvalidEnvironment :
        CrumbStartException("environment must be at most 64 printable characters")
    class InvalidRelease :
        CrumbStartException("release values must be non-empty, printable, and within contract limits")
    class InvalidScreenshotDimension :
        CrumbStartException("maximum screenshot dimension must be between 320 and 4096 pixels")
    class InvalidScreenshotByteLimit :
        CrumbStartException("maximum screenshot bytes must be between 65536 and 26214400")
    class InvalidDiagnosticsTimeout :
        CrumbStartException("diagnostic timeout must be between 250 and 5000 milliseconds")
    class InvalidHealthCheckUrl :
        CrumbStartException("healthCheckUrl must be an absolute HTTP or HTTPS URL without credentials or query values")
    class InvalidLogLookback :
        CrumbStartException("log lookback must be between 1000 and 300000 milliseconds")
    class InvalidLogLimits :
        CrumbStartException("log limits must be 1-500 entries and 1024-262144 bytes")
    class InvalidIngestionUrl :
        CrumbStartException("ingestionUrl must be an absolute HTTP or HTTPS base URL")
    class InvalidReporterFields :
        CrumbStartException("reporter.visibleFields must include description")
    class InvalidEvidence :
        CrumbStartException("evidence contains an unsupported category")
    class InvalidApplicationMetadata :
        CrumbStartException("application.name must be printable and at most 256 characters")
    class InvalidCustomContext :
        CrumbStartException("custom context must contain bounded, allowlisted string values")
    class InvalidWorkspacePolicyTimeout :
        CrumbStartException("workspace policy timeout must be between 250 and 5000 milliseconds")
    class InvalidWorkspacePolicyUrl :
        CrumbStartException("workspace policy url must be an absolute HTTP or HTTPS URL without credentials or query values")
    class AlreadyStarted : CrumbStartException("Crumb is already started with another configuration")
}

object Crumb {
    private val lock = Any()
    private var configuration: CrumbConfiguration? = null
    private var workspacePolicy: CrumbWorkspacePolicy? = null
    private val highestWorkspacePolicyVersionByScope = mutableMapOf<String, Int>()
    private var policyStatus: CrumbPolicyStatus = CrumbPolicyStatus.NOT_FETCHED
    private var javascriptCrashStore: CrumbJavaScriptCrashStore? = null

    @JvmStatic
    fun start(configuration: CrumbConfiguration) = synchronized(lock) {
        validate(configuration)
        val existing = this.configuration
        if (existing != null && existing != configuration) throw CrumbStartException.AlreadyStarted()
        if (existing == null) this.configuration = configuration
    }

    @JvmStatic
    fun canCollectLogs(): Boolean = synchronized(lock) {
        val activeConfiguration = configuration ?: return@synchronized false
        effectiveSettings(activeConfiguration).evidence.contains(CrumbEvidenceCategory.LOGS)
    }

    /** Records an opt-in JavaScript failure for recovery on the next launch. */
    @JvmStatic
    fun recordJavaScriptCrash(context: Context, crash: CrumbJavaScriptCrash): Boolean = synchronized(lock) {
        if (configuration == null) return@synchronized false
        crashStore(context).record(crash, reportSettings())
    }

    /** Converts pending JavaScript failures into the normal durable report queue. */
    @JvmStatic
    fun recoverPendingJavaScriptCrashes(context: Context): Int {
        val settings = synchronized(lock) {
            if (configuration == null) return@synchronized null
            reportSettings()
        } ?: return 0
        val applicationContext = context.applicationContext
        val store = synchronized(lock) { crashStore(applicationContext) }
        val runtime = CrumbJavaScriptCrashRuntime(
            osVersion = Build.VERSION.RELEASE?.takeIf(String::isNotBlank) ?: "unknown",
            deviceFamily = Build.MODEL?.takeIf(String::isNotBlank) ?: "Android",
            locale = Locale.getDefault().toLanguageTag(),
            timezone = TimeZone.getDefault().id,
            processName = applicationContext.packageName,
            processId = Process.myPid(),
        )
        return CrumbJavaScriptCrashRecovery.recoverPending(
            store = store,
            queue = CrumbReportQueue.from(applicationContext),
            settings = settings,
            runtime = runtime,
        )
    }

    /** Internal bridge for the native UI module; not part of the intended public SDK interface. */
    @JvmSynthetic
    fun reportSettings(): CrumbReportSettings = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        val effective = effectiveSettings(activeConfiguration)
        CrumbReportSettings(
            environment = activeConfiguration.environment,
            release = activeConfiguration.release,
            invocation = activeConfiguration.invocation,
            capture = activeConfiguration.capture,
            diagnostics = activeConfiguration.diagnostics,
            privacy = activeConfiguration.privacy,
            reporter = activeConfiguration.reporter.copy(
                visibleFields = effective.reporterFields,
            ),
            evidence = effective.evidence,
            application = activeConfiguration.application,
            customContext = effective.customContext,
            policyStatus = effective.status,
            workspacePolicyVersion = effective.workspacePolicyVersion,
        )
    }

    /** Internal bridge for the native UI policy coordinator. */
    @JvmSynthetic
    fun workspacePolicyFetchSettings(): CrumbPolicyFetchSettings? = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        activeConfiguration.workspacePolicy.url?.let {
            CrumbPolicyFetchSettings(
                projectKey = activeConfiguration.projectKey,
                url = it,
                timeoutMillis = activeConfiguration.workspacePolicy.timeoutMillis,
            )
        }
    }

    @JvmSynthetic
    fun workspacePolicyCacheKey(): String = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        val scope = CrumbPolicy.scopeKey(
            projectKey = activeConfiguration.projectKey,
            environment = activeConfiguration.environment,
            url = activeConfiguration.workspacePolicy.url,
        )
        "crumb.workspace-policy.${CrumbPolicy.sha256(scope)}"
    }

    @JvmSynthetic
    fun beginWorkspacePolicyFetch() = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        if (activeConfiguration.workspacePolicy.url != null) {
            policyStatus = if (workspacePolicy?.isValidAt(System.currentTimeMillis()) == true) {
                CrumbPolicyStatus.CACHED
            } else {
                CrumbPolicyStatus.FETCHING
            }
        }
    }

    @JvmSynthetic
    fun applyWorkspacePolicy(policy: CrumbWorkspacePolicy, source: CrumbPolicySource): Boolean = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        val now = System.currentTimeMillis()
        val scope = CrumbPolicy.scopeKey(
            projectKey = activeConfiguration.projectKey,
            environment = activeConfiguration.environment,
            url = activeConfiguration.workspacePolicy.url,
        )
        if (activeConfiguration.workspacePolicy.url == null ||
            !policy.isValidAt(now) ||
            (highestWorkspacePolicyVersionByScope[scope]?.let { policy.version < it } == true)
        ) {
            return@synchronized false
        }
        workspacePolicy = policy
        highestWorkspacePolicyVersionByScope[scope] = maxOf(
            highestWorkspacePolicyVersionByScope[scope] ?: 0,
            policy.version,
        )
        policyStatus = when (source) {
            CrumbPolicySource.FRESH -> CrumbPolicyStatus.FRESH
            CrumbPolicySource.CACHED -> CrumbPolicyStatus.CACHED
        }
        true
    }

    @JvmSynthetic
    fun markWorkspacePolicyUnavailable() = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        if (activeConfiguration.workspacePolicy.url != null &&
            workspacePolicy?.isValidAt(System.currentTimeMillis()) != true
        ) {
            workspacePolicy = null
            policyStatus = CrumbPolicyStatus.UNAVAILABLE
        }
    }

    /** Internal transport settings; the project write key never enters report UI or envelopes. */
    @JvmSynthetic
    fun uploadSettings(): CrumbUploadSettings? = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        activeConfiguration.upload.ingestionUrl?.let {
            CrumbUploadSettings(activeConfiguration.projectKey, it)
        }
    }

    /** Internal bridge for report creation; storage and transport consume the serialized result. */
    @JvmSynthetic
    fun buildReport(input: CrumbReportBuildInput): CrumbSerializedReportEnvelope = synchronized(lock) {
        val activeConfiguration = configuration ?: error("Crumb.start must be called first")
        val effective = effectiveSettings(activeConfiguration)
        CrumbReportEnvelopeBuilder.build(
            settings = CrumbReportSettings(
                environment = activeConfiguration.environment,
                release = activeConfiguration.release,
                invocation = activeConfiguration.invocation,
                capture = activeConfiguration.capture,
                diagnostics = activeConfiguration.diagnostics,
                privacy = activeConfiguration.privacy,
                reporter = activeConfiguration.reporter.copy(visibleFields = effective.reporterFields),
                evidence = effective.evidence,
                application = activeConfiguration.application,
                customContext = effective.customContext,
                policyStatus = effective.status,
                workspacePolicyVersion = effective.workspacePolicyVersion,
            ),
            input = input,
        )
    }

    @JvmSynthetic
    fun newReportId(): String = CrumbReportEnvelopeBuilder.makeReportId()

    @JvmSynthetic
    internal fun resetForTesting() = synchronized(lock) {
        configuration = null
        workspacePolicy = null
        highestWorkspacePolicyVersionByScope.clear()
        policyStatus = CrumbPolicyStatus.NOT_FETCHED
        javascriptCrashStore = null
    }

    private fun crashStore(context: Context): CrumbJavaScriptCrashStore =
        javascriptCrashStore ?: CrumbJavaScriptCrashStore.from(context).also {
            javascriptCrashStore = it
        }

    private fun validate(configuration: CrumbConfiguration) {
        if (configuration.projectKey.isBlank()) throw CrumbStartException.EmptyProjectKey()
        if (!configuration.projectKey.hasPrintableLength(512)) {
            throw CrumbStartException.InvalidProjectKey()
        }
        if (configuration.environment.isBlank()) throw CrumbStartException.EmptyEnvironment()
        if (!configuration.environment.hasPrintableLength(64)) {
            throw CrumbStartException.InvalidEnvironment()
        }
        if (
            !configuration.release.appVersion.hasPrintableLength(64) ||
            !configuration.release.nativeBuild.hasPrintableLength(64) ||
            configuration.release.bundleVersion?.hasPrintableLength(128) == false
        ) {
            throw CrumbStartException.InvalidRelease()
        }
        if (configuration.capture.maximumScreenshotDimension !in 320..4_096) {
            throw CrumbStartException.InvalidScreenshotDimension()
        }
        if (configuration.capture.maximumScreenshotBytes !in 65_536..26_214_400) {
            throw CrumbStartException.InvalidScreenshotByteLimit()
        }
        if (configuration.diagnostics.timeoutMillis !in 250..5_000) {
            throw CrumbStartException.InvalidDiagnosticsTimeout()
        }
        configuration.diagnostics.healthCheckUrl?.let { value ->
            if (!validHttpUrl(value)) throw CrumbStartException.InvalidHealthCheckUrl()
        }
        if (configuration.diagnostics.logs.lookbackMillis !in 1_000..300_000) {
            throw CrumbStartException.InvalidLogLookback()
        }
        if (
            configuration.diagnostics.logs.maximumEntries !in 1..500 ||
            configuration.diagnostics.logs.maximumBytes !in 1_024..262_144
        ) {
            throw CrumbStartException.InvalidLogLimits()
        }
        if (CrumbReporterField.DESCRIPTION !in configuration.reporter.visibleFields) {
            throw CrumbStartException.InvalidReporterFields()
        }
        if (configuration.evidence.size > CrumbEvidenceCategory.entries.size) {
            throw CrumbStartException.InvalidEvidence()
        }
        configuration.application.name?.let {
            if (!it.hasPrintableLength(256)) throw CrumbStartException.InvalidApplicationMetadata()
        }
        if (
            configuration.customContext.values.size > CrumbCustomContextSanitizer.maximumKeys ||
            configuration.customContext.allowedKeys.size > CrumbCustomContextSanitizer.maximumKeys ||
            configuration.customContext.values.keys.any { !CrumbCustomContextSanitizer.isValidKey(it) } ||
            configuration.customContext.allowedKeys.any { !CrumbCustomContextSanitizer.isValidKey(it) }
        ) {
            throw CrumbStartException.InvalidCustomContext()
        }
        if (configuration.workspacePolicy.timeoutMillis !in 250..5_000) {
            throw CrumbStartException.InvalidWorkspacePolicyTimeout()
        }
        configuration.workspacePolicy.url?.let { value ->
            if (!validHttpUrl(value)) throw CrumbStartException.InvalidWorkspacePolicyUrl()
        }
        configuration.upload.ingestionUrl?.let { value ->
            if (!validHttpUrl(value)) {
                throw CrumbStartException.InvalidIngestionUrl()
            }
        }
    }

    private fun validHttpUrl(value: String): Boolean {
        val uri = runCatching { java.net.URI(value) }.getOrNull()
        return uri != null && uri.isAbsolute && !uri.host.isNullOrBlank() &&
            uri.scheme?.lowercase() in setOf("http", "https") &&
            uri.userInfo == null && uri.query == null && uri.fragment == null
    }

    private fun String.hasPrintableLength(maximum: Int): Boolean =
        isNotBlank() && length <= maximum && none { it.isISOControl() }

    private fun effectiveSettings(configuration: CrumbConfiguration): CrumbEffectivePolicy {
        val now = System.currentTimeMillis()
        val status = when {
            configuration.workspacePolicy.url == null -> CrumbPolicyStatus.NOT_CONFIGURED
            workspacePolicy?.isValidAt(now) == true -> policyStatus
            workspacePolicy != null -> CrumbPolicyStatus.EXPIRED
            else -> policyStatus
        }
        return CrumbPolicyEvaluator.effective(
            configuration = configuration,
            workspacePolicy = workspacePolicy?.takeIf { it.isValidAt(now) },
            status = status,
            nowMillis = now,
        )
    }
}
