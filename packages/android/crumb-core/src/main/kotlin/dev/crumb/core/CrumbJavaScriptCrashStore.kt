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
)

data class CrumbJavaScriptCrashStoreLimits(
    val maximumRecords: Int = 50,
    val maximumTotalBytes: Long = 2_097_152,
    val maximumRecordBytes: Int = 32_768,
    val maximumBreadcrumbs: Int = 32,
    val maximumBreadcrumbBytes: Int = 16_384,
)

/** Small synchronous persistence for the React Native JavaScript handoff. */
class CrumbJavaScriptCrashStore internal constructor(
    private val root: File,
    private val limits: CrumbJavaScriptCrashStoreLimits = CrumbJavaScriptCrashStoreLimits(),
) {
    fun record(recordJson: String): Boolean = synchronized(STORAGE_LOCK) {
        if (!validLimits()) return false
        val bytes = recordJson.toByteArray(StandardCharsets.UTF_8)
        if (bytes.size > limits.maximumRecordBytes) return false
        val incoming = parse(recordJson) ?: return false
        return runCatching {
            if (!root.exists() && !root.mkdirs() && !root.isDirectory) return false
            val existing = readAll()
            val match = existing.firstOrNull { it.record.fingerprint == incoming.fingerprint }
            if (match != null) {
                val merged = merge(match.record, incoming)
                val mergedBytes = encode(merged).toByteArray(StandardCharsets.UTF_8)
                val total = existing.sumOf { encode(it.record).toByteArray(StandardCharsets.UTF_8).size.toLong() } -
                    encode(match.record).toByteArray(StandardCharsets.UTF_8).size + mergedBytes.size
                if (mergedBytes.size > limits.maximumRecordBytes || total > limits.maximumTotalBytes) {
                    return false
                }
                write(File(root, "${match.record.recordId}.json"), mergedBytes)
                true
            } else {
                val encoded = encode(incoming).toByteArray(StandardCharsets.UTF_8)
                val total = existing.sumOf { encode(it.record).toByteArray(StandardCharsets.UTF_8).size.toLong() }
                if (
                    existing.size >= limits.maximumRecords ||
                    encoded.size > limits.maximumRecordBytes ||
                    total + encoded.size > limits.maximumTotalBytes
                ) {
                    false
                } else {
                    write(File(root, "${incoming.recordId}.json"), encoded)
                    true
                }
            }
        }.getOrDefault(false)
    }

    fun records(): List<CrumbJavaScriptCrash> = synchronized(STORAGE_LOCK) {
        if (!validLimits()) return emptyList()
        if (!root.exists() && !root.mkdirs() && !root.isDirectory) return emptyList()
        val byFingerprint = linkedMapOf<String, Pair<File, CrumbJavaScriptCrash>>()
        readAll().forEach { entry ->
            val previous = byFingerprint[entry.record.fingerprint]
            if (previous == null) {
                byFingerprint[entry.record.fingerprint] = entry.file to entry.record
            } else {
                val merged = merge(previous.second, entry.record)
                runCatching { write(previous.first, encode(merged).toByteArray(StandardCharsets.UTF_8)) }
                entry.file.delete()
                byFingerprint[entry.record.fingerprint] = previous.first to merged
            }
        }
        return byFingerprint.values
            .map { it.second }
            .sortedBy(CrumbJavaScriptCrash::occurredAt)
    }

    fun remove(recordId: String): Boolean = synchronized(STORAGE_LOCK) {
        if (!recordId.matches(RECORD_ID_PATTERN)) return false
        return File(root, "$recordId.json").takeIf(File::isFile)?.delete() == true
    }

    private fun readAll(): List<Entry> = root.listFiles()
        ?.filter { it.isFile && it.extension == "json" }
        ?.mapNotNull { file ->
            if (!file.nameWithoutExtension.matches(RECORD_ID_PATTERN)) {
                if (file.name.startsWith(".tmp-")) file.delete()
                return@mapNotNull null
            }
            val parsed = runCatching { parse(file.readText()) }.getOrNull()
            if (parsed == null) {
                file.delete()
                null
            } else {
                Entry(file, parsed)
            }
        }
        .orEmpty()

    private fun parse(json: String): CrumbJavaScriptCrash? = runCatching {
        val objectValue = JSONObject(json)
        require(objectValue.optString("schema_version") == "1.0")
        val recordId = objectValue.optString("record_id")
        val fingerprint = objectValue.optString("fingerprint").lowercase(Locale.ROOT)
        val source = objectValue.optString("source")
        val kind = objectValue.optString("kind")
        require(recordId.matches(RECORD_ID_PATTERN))
        require(fingerprint.matches(FINGERPRINT_PATTERN))
        require(source in setOf("javascript", "native_termination_wrapper"))
        require(kind in setOf("exception", "unhandled_rejection", "native_termination_wrapper"))
        val type = sanitizeText(objectValue.optString("type")).trim().bounded(128)
        val message = sanitizeText(objectValue.optString("message")).trim().bounded(4_000)
        require(type.isNotEmpty() && message.isNotEmpty())
        val occurredAt = Instant.parse(objectValue.optString("occurred_at"))
        val releaseObject = objectValue.optJSONObject("release")
        val release = CrumbJavaScriptCrashRelease(
            appVersion = releaseObject.optionalString("app_version")?.bounded(64),
            nativeBuild = releaseObject.optionalString("native_build")?.bounded(64),
            bundleVersion = releaseObject.optionalString("bundle_version")?.bounded(128),
        )
        val stack = if (objectValue.has("stack") && !objectValue.isNull("stack")) {
            sanitizeText(objectValue.optString("stack"), preserveNewlines = true)
                .trim()
                .bounded(16_384)
                .takeIf(String::isNotEmpty)
        } else {
            null
        }
        val breadcrumbs = boundedBreadcrumbs(objectValue.optJSONArray("breadcrumbs"))
        val rawContext = linkedMapOf<String, String>()
        objectValue.optJSONObject("context")?.let { contextObject ->
            val keys = contextObject.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (!contextObject.isNull(key) && contextObject.get(key) is String) {
                    rawContext[key] = contextObject.getString(key)
                }
            }
        }
        val context = CrumbCustomContextSanitizer.sanitize(
            CrumbCustomContextOptions(values = rawContext, allowedKeys = rawContext.keys),
        )
        CrumbJavaScriptCrash(
            recordId = recordId,
            fingerprint = fingerprint,
            source = source,
            kind = kind,
            type = type,
            message = message,
            stack = stack,
            occurredAt = occurredAt,
            release = release,
            breadcrumbs = breadcrumbs,
            context = context,
            isFatal = objectValue.optBoolean("is_fatal", false) || source == "native_termination_wrapper",
            nativeTerminationWrapperObserved = objectValue.optBoolean(
                "native_termination_wrapper_observed",
                false,
            ) || source == "native_termination_wrapper",
        )
    }.getOrNull()

    private fun boundedBreadcrumbs(array: JSONArray?): List<CrumbJavaScriptBreadcrumb> {
        if (array == null || limits.maximumBreadcrumbs == 0) return emptyList()
        val values = buildList {
            for (index in 0 until array.length()) {
                val objectValue = array.optJSONObject(index) ?: continue
                val breadcrumb = runCatching {
                    CrumbJavaScriptBreadcrumb(
                        timestamp = Instant.parse(objectValue.optString("timestamp")),
                        source = sanitizeText(objectValue.optString("source")).bounded(64),
                        category = sanitizeText(objectValue.optString("category")).bounded(256),
                        message = sanitizeText(objectValue.optString("message")).bounded(2_048),
                    )
                }.getOrNull() ?: continue
                if (breadcrumb.source.isNotEmpty() && breadcrumb.category.isNotEmpty() && breadcrumb.message.isNotEmpty()) {
                    add(breadcrumb)
                }
            }
        }
        var bytes = 0
        return values.takeLast(limits.maximumBreadcrumbs).filter { breadcrumb ->
            val size = encodeBreadcrumb(breadcrumb).toByteArray(StandardCharsets.UTF_8).size
            if (bytes + size > limits.maximumBreadcrumbBytes) false else {
                bytes += size
                true
            }
        }
    }

    private fun merge(
        existing: CrumbJavaScriptCrash,
        incoming: CrumbJavaScriptCrash,
    ): CrumbJavaScriptCrash {
        val preferred = if (incoming.source == "javascript" && existing.source != "javascript") incoming else existing
        val fallback = if (preferred.recordId == incoming.recordId) existing else incoming
        return preferred.copy(
            stack = preferred.stack ?: fallback.stack,
            occurredAt = minOf(existing.occurredAt, incoming.occurredAt),
            release = CrumbJavaScriptCrashRelease(
                appVersion = preferred.release.appVersion ?: fallback.release.appVersion,
                nativeBuild = preferred.release.nativeBuild ?: fallback.release.nativeBuild,
                bundleVersion = preferred.release.bundleVersion ?: fallback.release.bundleVersion,
            ),
            breadcrumbs = preferred.breadcrumbs.ifEmpty { fallback.breadcrumbs },
            context = preferred.context.ifEmpty { fallback.context },
            isFatal = existing.isFatal || incoming.isFatal,
            nativeTerminationWrapperObserved = existing.nativeTerminationWrapperObserved ||
                incoming.nativeTerminationWrapperObserved,
        )
    }

    private fun encode(record: CrumbJavaScriptCrash): String = JSONObject().apply {
        put("schema_version", "1.0")
        put("record_id", record.recordId)
        put("fingerprint", record.fingerprint)
        put("source", record.source)
        put("kind", record.kind)
        put("type", record.type)
        put("message", record.message)
        record.stack?.let { put("stack", it) }
        put("occurred_at", record.occurredAt.toString())
        put("release", JSONObject().apply {
            record.release.appVersion?.let { put("app_version", it) }
            record.release.nativeBuild?.let { put("native_build", it) }
            record.release.bundleVersion?.let { put("bundle_version", it) }
        })
        put("breadcrumbs", JSONArray().apply {
            record.breadcrumbs.forEach { breadcrumb ->
                put(JSONObject().apply {
                    put("timestamp", breadcrumb.timestamp.toString())
                    put("source", breadcrumb.source)
                    put("category", breadcrumb.category)
                    put("message", breadcrumb.message)
                })
            }
        })
        put("context", JSONObject().apply {
            record.context.forEach { (key, value) -> put(key, value) }
        })
        put("is_fatal", record.isFatal)
        put("native_termination_wrapper_observed", record.nativeTerminationWrapperObserved)
    }.toString()

    private fun encodeBreadcrumb(breadcrumb: CrumbJavaScriptBreadcrumb): String =
        JSONObject().apply {
            put("timestamp", breadcrumb.timestamp.toString())
            put("source", breadcrumb.source)
            put("category", breadcrumb.category)
            put("message", breadcrumb.message)
        }.toString()

    private fun write(target: File, bytes: ByteArray) {
        if (!root.exists()) root.mkdirs()
        val temporary = File(root, ".tmp-${UUID.randomUUID()}.json")
        FileOutputStream(temporary).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
        try {
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: Exception) {
            Files.move(
                temporary.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        } finally {
            temporary.delete()
        }
    }

    private fun validLimits(): Boolean =
        limits.maximumRecords > 0 &&
            limits.maximumTotalBytes > 0 &&
            limits.maximumRecordBytes > 0 &&
            limits.maximumRecordBytes.toLong() <= limits.maximumTotalBytes &&
            limits.maximumBreadcrumbs >= 0 &&
            limits.maximumBreadcrumbBytes > 0

    private fun String.bounded(maximumBytes: Int): String {
        if (toByteArray(StandardCharsets.UTF_8).size <= maximumBytes) return this
        var result = this
        while (result.isNotEmpty() && result.toByteArray(StandardCharsets.UTF_8).size > maximumBytes) {
            result = result.dropLast(1)
        }
        return result
    }

    private fun sanitizeText(value: String, preserveNewlines: Boolean = false): String {
        var sanitized = value
        REDACTIONS.forEach { (pattern, replacement) -> sanitized = pattern.replace(sanitized, replacement) }
        return sanitized.map { character ->
            if (character == '\n' && preserveNewlines) character
            else if (character == '\t' && preserveNewlines) character
            else if (character.isISOControl()) ' ' else character
        }.joinToString("")
    }

    private data class Entry(val file: File, val record: CrumbJavaScriptCrash)

    private companion object {
        val STORAGE_LOCK = Any()
        val RECORD_ID_PATTERN = Regex("^jsc_[A-Za-z0-9_-]{16,80}$")
        val FINGERPRINT_PATTERN = Regex("^[a-f0-9]{16}$")
        val REDACTIONS = listOf(
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

        private fun JSONObject?.optionalString(name: String): String? =
            if (this != null && has(name) && !isNull(name)) getString(name) else null
    }
}
