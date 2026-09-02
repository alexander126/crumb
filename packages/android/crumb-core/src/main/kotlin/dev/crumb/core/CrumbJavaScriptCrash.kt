package dev.crumb.core

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

enum class CrumbJavaScriptCrashKind(val wireValue: String) {
    FATAL_EXCEPTION("fatal_exception"),
    UNHANDLED_REJECTION("unhandled_rejection"),
}

enum class CrumbJavaScriptCrashSource(val wireValue: String) {
    JAVASCRIPT("javascript"),
    NATIVE_TERMINATION_WRAPPER("native_termination_wrapper"),
}

data class CrumbJavaScriptBreadcrumb(
    val timestampMillis: Long,
    val category: String,
    val message: String,
)

data class CrumbJavaScriptCrash(
    val kind: CrumbJavaScriptCrashKind,
    val source: CrumbJavaScriptCrashSource = CrumbJavaScriptCrashSource.JAVASCRIPT,
    val errorType: String,
    val message: String,
    val rawStack: String? = null,
    val fingerprint: String? = null,
    val occurredAtMillis: Long = System.currentTimeMillis(),
    val nativeTerminationWrapper: Boolean = false,
    val breadcrumbs: List<CrumbJavaScriptBreadcrumb> = emptyList(),
)

internal data class CrumbJavaScriptCrashRecord(
    val reportId: String,
    val appVersion: String,
    val nativeBuild: String,
    val bundleVersion: String?,
    val environment: String,
    val applicationName: String?,
    val customContext: Map<String, String>,
    val policyStatus: String,
    val workspacePolicyVersion: Int?,
    val crash: CrumbJavaScriptCrash,
)

internal data class CrumbJavaScriptCrashRuntime(
    val osVersion: String,
    val deviceFamily: String,
    val locale: String,
    val timezone: String,
    val processName: String,
    val processId: Int,
)

internal class CrumbJavaScriptCrashStore internal constructor(
    private val root: File,
) {
    private val lock = Any()
    private val file = File(root, PENDING_FILE)

    fun record(crash: CrumbJavaScriptCrash, settings: CrumbReportSettings): Boolean {
        val normalized = CrumbJavaScriptCrashSanitizer.normalize(crash) ?: return false
        return synchronized(lock) {
            val records = readRecords().toMutableList()
            val incoming = CrumbJavaScriptCrashRecord(
                reportId = CrumbReportEnvelopeBuilder.makeReportId(),
                appVersion = settings.release.appVersion,
                nativeBuild = settings.release.nativeBuild,
                bundleVersion = settings.release.bundleVersion,
                environment = settings.environment,
                applicationName = settings.application.name,
                customContext = settings.customContext,
                policyStatus = settings.policyStatus.wireValue,
                workspacePolicyVersion = settings.workspacePolicyVersion,
                crash = normalized,
            )
            val index = records.indexOfFirst { it.crash.fingerprint == normalized.fingerprint }
            if (index >= 0) {
                records[index] = merge(records[index], incoming)
            } else {
                if (records.size >= MAXIMUM_RECORDS) return@synchronized false
                records += incoming
            }
            writeRecords(records)
        }
    }

    fun records(): List<CrumbJavaScriptCrashRecord> = synchronized(lock) { readRecords() }

    fun remove(reportId: String): Boolean = synchronized(lock) {
        val records = readRecords().toMutableList()
        val changed = records.removeAll { it.reportId == reportId }
        if (!changed) return@synchronized true
        writeRecords(records)
    }

    private fun merge(
        existing: CrumbJavaScriptCrashRecord,
        incoming: CrumbJavaScriptCrashRecord,
    ): CrumbJavaScriptCrashRecord {
        val javascript = when {
            incoming.crash.source == CrumbJavaScriptCrashSource.JAVASCRIPT -> incoming.crash
            existing.crash.source == CrumbJavaScriptCrashSource.JAVASCRIPT -> existing.crash
            else -> incoming.crash
        }
        val source = if (
            existing.crash.source == CrumbJavaScriptCrashSource.JAVASCRIPT ||
            incoming.crash.source == CrumbJavaScriptCrashSource.JAVASCRIPT
        ) {
            CrumbJavaScriptCrashSource.JAVASCRIPT
        } else {
            CrumbJavaScriptCrashSource.NATIVE_TERMINATION_WRAPPER
        }
        return existing.copy(
            crash = CrumbJavaScriptCrash(
                kind = javascript.kind,
                source = source,
                errorType = javascript.errorType,
                message = javascript.message,
                rawStack = javascript.rawStack ?: existing.crash.rawStack ?: incoming.crash.rawStack,
                fingerprint = javascript.fingerprint,
                occurredAtMillis = minOf(existing.crash.occurredAtMillis, incoming.crash.occurredAtMillis),
                nativeTerminationWrapper = existing.crash.nativeTerminationWrapper ||
                    incoming.crash.nativeTerminationWrapper ||
                    source == CrumbJavaScriptCrashSource.NATIVE_TERMINATION_WRAPPER,
                breadcrumbs = mergeBreadcrumbs(existing.crash.breadcrumbs, incoming.crash.breadcrumbs),
            ),
        )
    }

    private fun mergeBreadcrumbs(
        first: List<CrumbJavaScriptBreadcrumb>,
        second: List<CrumbJavaScriptBreadcrumb>,
    ): List<CrumbJavaScriptBreadcrumb> {
        val result = mutableListOf<CrumbJavaScriptBreadcrumb>()
        (first + second).sortedBy(CrumbJavaScriptBreadcrumb::timestampMillis).forEach { breadcrumb ->
            if (breadcrumb in result || result.size >= MAXIMUM_BREADCRUMBS) return@forEach
            val bytes = result.sumOf { crumbUtf8Bytes(it.category) + crumbUtf8Bytes(it.message) + 32 } +
                crumbUtf8Bytes(breadcrumb.category) + crumbUtf8Bytes(breadcrumb.message) + 32
            if (bytes <= MAXIMUM_BREADCRUMB_BYTES) result += breadcrumb
        }
        return result
    }

    private fun readRecords(): List<CrumbJavaScriptCrashRecord> {
        if (!file.isFile || file.length() > MAXIMUM_FILE_BYTES) return emptyList()
        return runCatching {
            val array = JSONArray(file.readText(Charsets.UTF_8))
            (0 until array.length()).mapNotNull { index ->
                array.optJSONObject(index)?.toRecord()
            }
        }.getOrDefault(emptyList())
    }

    private fun writeRecords(records: List<CrumbJavaScriptCrashRecord>): Boolean {
        var temporary: File? = null
        return runCatching {
            if (!root.exists() && !root.mkdirs()) error("could not create crash directory")
            if (!root.isDirectory) error("crash path is not a directory")
            val bytes = records.toJson().toString().toByteArray(Charsets.UTF_8)
            if (bytes.size > MAXIMUM_FILE_BYTES) return@runCatching false
            val target = File(root, "$TEMPORARY_PREFIX${UUID.randomUUID()}")
            temporary = target
            FileOutputStream(target).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
            try {
                Files.move(
                    target.toPath(),
                    file.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(
                    target.toPath(),
                    file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
            true
        }.getOrElse {
            temporary?.delete()
            false
        }
    }

    private fun CrumbJavaScriptCrashRecord.toJson(): JSONObject = JSONObject().apply {
        put("report_id", reportId)
        put("app_version", appVersion)
        put("native_build", nativeBuild)
        putOptional("bundle_version", bundleVersion)
        put("environment", environment)
        putOptional("application_name", applicationName)
        put("custom_context", JSONObject().apply {
            customContext.forEach { (key, value) -> put(key, value) }
        })
        put("policy_status", policyStatus)
        putOptional("policy_version", workspacePolicyVersion)
        put("crash", crash.toJson())
    }

    private fun CrumbJavaScriptCrash.toJson(): JSONObject = JSONObject().apply {
        put("kind", kind.wireValue)
        put("source", source.wireValue)
        put("error_type", errorType)
        put("message", message)
        putOptional("raw_stack", rawStack)
        putOptional("fingerprint", fingerprint)
        put("occurred_at_millis", occurredAtMillis)
        put("native_termination_wrapper", nativeTerminationWrapper)
        put("breadcrumbs", JSONArray().apply {
            breadcrumbs.forEach { breadcrumb ->
                put(JSONObject().apply {
                    put("timestamp_millis", breadcrumb.timestampMillis)
                    put("category", breadcrumb.category)
                    put("message", breadcrumb.message)
                })
            }
        })
    }

    private fun JSONObject.toRecord(): CrumbJavaScriptCrashRecord? = runCatching {
        val crashObject = getJSONObject("crash")
        val kind = CrumbJavaScriptCrashKind.entries.first { it.wireValue == crashObject.getString("kind") }
        val source = CrumbJavaScriptCrashSource.entries.first { it.wireValue == crashObject.getString("source") }
        val breadcrumbs = crashObject.optJSONArray("breadcrumbs")?.let { array ->
            (0 until array.length()).mapNotNull { index ->
                array.optJSONObject(index)?.let { breadcrumb ->
                    CrumbJavaScriptBreadcrumb(
                        timestampMillis = breadcrumb.getLong("timestamp_millis"),
                        category = breadcrumb.getString("category"),
                        message = breadcrumb.getString("message"),
                    )
                }
            }
        }.orEmpty()
        CrumbJavaScriptCrashRecord(
            reportId = getString("report_id"),
            appVersion = getString("app_version"),
            nativeBuild = getString("native_build"),
            bundleVersion = optionalString("bundle_version"),
            environment = getString("environment"),
            applicationName = optionalString("application_name"),
            customContext = optJSONObject("custom_context")?.let { context ->
                context.keys().asSequence().associateWith(context::getString)
            }.orEmpty(),
            policyStatus = getString("policy_status"),
            workspacePolicyVersion = if (has("policy_version") && !isNull("policy_version")) {
                getInt("policy_version")
            } else {
                null
            },
            crash = CrumbJavaScriptCrash(
                kind = kind,
                source = source,
                errorType = crashObject.getString("error_type"),
                message = crashObject.getString("message"),
                rawStack = crashObject.optionalString("raw_stack"),
                fingerprint = crashObject.optionalString("fingerprint"),
                occurredAtMillis = crashObject.getLong("occurred_at_millis"),
                nativeTerminationWrapper = crashObject.optBoolean("native_termination_wrapper"),
                breadcrumbs = breadcrumbs,
            ),
        )
    }.getOrNull()

    private fun List<CrumbJavaScriptCrashRecord>.toJson(): JSONArray = JSONArray().apply {
        forEach { put(it.toJson()) }
    }

    private fun JSONObject.putOptional(name: String, value: Any?) {
        if (value != null) put(name, value)
    }

    private fun JSONObject.optionalString(name: String): String? =
        if (has(name) && !isNull(name)) getString(name) else null

    companion object {
        private const val PENDING_FILE = "pending-javascript-crashes.json"
        private const val TEMPORARY_PREFIX = ".pending-javascript-crash-"
        private const val MAXIMUM_RECORDS = 8
        private const val MAXIMUM_FILE_BYTES = 262_144L
        private const val MAXIMUM_BREADCRUMBS = 32
        private const val MAXIMUM_BREADCRUMB_BYTES = 16_384

        fun from(context: Context): CrumbJavaScriptCrashStore = CrumbJavaScriptCrashStore(
            File(File(context.applicationContext.noBackupFilesDir, "dev.crumb"), "javascript")
        )
    }
}

internal object CrumbJavaScriptCrashSanitizer {
    private const val MAXIMUM_ERROR_TYPE_BYTES = 128
    private const val MAXIMUM_MESSAGE_BYTES = 4_096
    private const val MAXIMUM_STACK_BYTES = 16_384
    private const val MAXIMUM_BREADCRUMB_CATEGORY_BYTES = 64
    private const val MAXIMUM_BREADCRUMB_MESSAGE_BYTES = 2_048
    private const val MAXIMUM_BREADCRUMBS = 32
    private const val MAXIMUM_BREADCRUMB_BYTES = 16_384
    private val replacements = listOf(
        Regex("(?i)(https?://)[^/\\s:@]+:[^/@\\s]+@") to "$1[REDACTED]@",
        Regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+") to "Bearer [REDACTED]",
        Regex(
            "(?i)\\b(authorization|cookie|set-cookie|password|passwd|secret|token|api[_-]?key)" +
                "\\s*[:=]\\s*(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
        ) to "$1=[REDACTED]",
        Regex("(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b") to "[REDACTED_EMAIL]",
        Regex("\\b(?:\\d[ -]*?){13,19}\\b") to "[REDACTED_NUMBER]",
        Regex("([?&][A-Za-z0-9._~-]+)=([^&#\\s]*)") to "$1=[REDACTED]",
    )

    fun normalize(crash: CrumbJavaScriptCrash): CrumbJavaScriptCrash? {
        if (crash.occurredAtMillis < 0) return null
        val errorType = sanitize(crash.errorType, MAXIMUM_ERROR_TYPE_BYTES)
            .ifBlank { "JavaScriptError" }
        val message = sanitize(crash.message, MAXIMUM_MESSAGE_BYTES)
        if (message.isBlank()) return null
        val rawStack = crash.rawStack?.let { sanitize(it, MAXIMUM_STACK_BYTES, true) }
            ?.takeIf(String::isNotBlank)
        val breadcrumbs = crash.breadcrumbs.mapNotNull { breadcrumb ->
            if (breadcrumb.timestampMillis < 0) return@mapNotNull null
            val category = sanitize(breadcrumb.category, MAXIMUM_BREADCRUMB_CATEGORY_BYTES)
            val message = sanitize(breadcrumb.message, MAXIMUM_BREADCRUMB_MESSAGE_BYTES)
            if (category.isBlank() || message.isBlank()) null else {
                CrumbJavaScriptBreadcrumb(breadcrumb.timestampMillis, category, message)
            }
        }.takeLast(MAXIMUM_BREADCRUMBS).let { values ->
            val result = mutableListOf<CrumbJavaScriptBreadcrumb>()
            var bytes = 0
            values.forEach { breadcrumb ->
                val size = crumbUtf8Bytes(breadcrumb.category) + crumbUtf8Bytes(breadcrumb.message) + 32
                if (bytes + size <= MAXIMUM_BREADCRUMB_BYTES) {
                    result += breadcrumb
                    bytes += size
                }
            }
            result
        }
        val fingerprint = if (crash.fingerprint?.matches(IDENTIFIER_PATTERN) == true) {
            crash.fingerprint
        } else {
            "js_" + CrumbPolicy.sha256(
                listOf(crash.kind.wireValue, errorType, message, rawStack.orEmpty())
                    .joinToString("|")
            )
        }
        return CrumbJavaScriptCrash(
            kind = crash.kind,
            source = crash.source,
            errorType = errorType,
            message = message,
            rawStack = rawStack,
            fingerprint = fingerprint,
            occurredAtMillis = crash.occurredAtMillis,
            nativeTerminationWrapper = crash.nativeTerminationWrapper ||
                crash.source == CrumbJavaScriptCrashSource.NATIVE_TERMINATION_WRAPPER,
            breadcrumbs = breadcrumbs,
        )
    }

    fun truncateUtf8(value: String, maximumBytes: Int): String {
        if (crumbUtf8Bytes(value) <= maximumBytes) return value
        val result = StringBuilder()
        value.forEach { character ->
            val candidate = result.toString() + character
            if (crumbUtf8Bytes(candidate) + 3 > maximumBytes) return@forEach
            result.append(character)
        }
        return "$result…"
    }

    private fun sanitize(value: String, maximumBytes: Int, preserveLineBreaks: Boolean = false): String {
        val replaced = replacements.fold(value) { result, (pattern, replacement) ->
            result.replace(pattern, replacement)
        }
        val printable = replaced.map { character ->
            if (preserveLineBreaks && (character == '\n' || character == '\r')) {
                character
            } else if (character.isISOControl()) {
                ' '
            } else {
                character
            }
        }.joinToString("").trim()
        return truncateUtf8(printable, maximumBytes)
    }

    private val IDENTIFIER_PATTERN = Regex("^[A-Za-z0-9._-]{1,128}$")
}

private fun crumbUtf8Bytes(value: String): Int = value.toByteArray(Charsets.UTF_8).size
