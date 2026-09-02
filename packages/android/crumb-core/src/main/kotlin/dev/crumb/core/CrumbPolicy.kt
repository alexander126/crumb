package dev.crumb.core

import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.util.Locale

object CrumbConfigurationContract {
    const val VERSION = "1.0"
}

enum class CrumbPolicyStatus(val wireValue: String) {
    NOT_CONFIGURED("not_configured"),
    NOT_FETCHED("not_fetched"),
    FETCHING("fetching"),
    FRESH("fresh"),
    CACHED("cached"),
    UNAVAILABLE("unavailable"),
    EXPIRED("expired"),
}

enum class CrumbPolicySource { FRESH, CACHED }

class CrumbWorkspacePolicyException(message: String) : IllegalArgumentException(message)

data class CrumbWorkspacePolicy(
    val version: Int,
    val expiresAtMillis: Long,
    val disabledEvidence: Set<CrumbEvidenceCategory> = emptySet(),
    val hiddenReporterFields: Set<CrumbReporterField> = emptySet(),
    val allowedContextKeys: Set<String> = emptySet(),
) {
    fun isValidAt(nowMillis: Long = System.currentTimeMillis()): Boolean =
        version > 0 &&
            expiresAtMillis > nowMillis &&
            disabledEvidence.size <= CrumbEvidenceCategory.entries.size &&
            hiddenReporterFields.size <= CrumbReporterField.entries.size &&
            CrumbReporterField.DESCRIPTION !in hiddenReporterFields &&
            allowedContextKeys.size <= CrumbCustomContextSanitizer.maximumKeys &&
            allowedContextKeys.all(CrumbCustomContextSanitizer::isValidKey)

    companion object {
        private val keys = setOf(
            "schema_version",
            "version",
            "expires_at",
            "disabled_evidence",
            "hidden_reporter_fields",
            "allowed_context_keys",
        )

        fun fromJson(
            value: String,
            nowMillis: Long = System.currentTimeMillis(),
        ): CrumbWorkspacePolicy {
            if (value.toByteArray(StandardCharsets.UTF_8).size > CrumbPolicyCache.maximumBytes) {
                throw CrumbWorkspacePolicyException("policy exceeds cache limit")
            }
            val json = runCatching { JSONObject(value) }.getOrElse {
                throw CrumbWorkspacePolicyException("policy is not valid JSON")
            }
            val actualKeys = json.keys().asSequence().toSet()
            if (actualKeys != keys) throw CrumbWorkspacePolicyException("policy keys are not exact")
            if (json.requireString("schema_version") != CrumbConfigurationContract.VERSION) {
                throw CrumbWorkspacePolicyException("policy schema version is unsupported")
            }
            val version = json.requireInt("version")
            if (version < 1) throw CrumbWorkspacePolicyException("policy version must be positive")
            val expiresAt = runCatching {
                Instant.parse(json.requireString("expires_at")).toEpochMilli()
            }.getOrElse {
                throw CrumbWorkspacePolicyException("policy expiry is invalid")
            }
            if (expiresAt <= nowMillis) throw CrumbWorkspacePolicyException("policy is expired")

            val disabledEvidence = json.enumSet("disabled_evidence", 16) { raw ->
                when (raw) {
                    "screenshot" -> CrumbEvidenceCategory.SCREENSHOT
                    "performance" -> CrumbEvidenceCategory.PERFORMANCE
                    "network" -> CrumbEvidenceCategory.NETWORK
                    "logs" -> CrumbEvidenceCategory.LOGS
                    "thread_stacks" -> CrumbEvidenceCategory.THREAD_STACKS
                    "health_check" -> CrumbEvidenceCategory.HEALTH_CHECK
                    "custom_context" -> CrumbEvidenceCategory.CUSTOM_CONTEXT
                    else -> throw CrumbWorkspacePolicyException("policy evidence value is unsupported")
                }
            }
            val hiddenReporterFields = json.enumSet("hidden_reporter_fields", 2) { raw ->
                when (raw) {
                    "category" -> CrumbReporterField.CATEGORY
                    "description" -> throw CrumbWorkspacePolicyException(
                        "description cannot be hidden from the report contract",
                    )
                    else -> throw CrumbWorkspacePolicyException("policy reporter field is unsupported")
                }
            }
            val allowedContextKeys = json.stringSet("allowed_context_keys", 16) { raw ->
                if (!CrumbCustomContextSanitizer.isValidKey(raw)) {
                    throw CrumbWorkspacePolicyException("policy context key is invalid")
                }
                raw
            }
            return CrumbWorkspacePolicy(
                version = version,
                expiresAtMillis = expiresAt,
                disabledEvidence = disabledEvidence,
                hiddenReporterFields = hiddenReporterFields,
                allowedContextKeys = allowedContextKeys,
            )
        }
    }
}

data class CrumbEffectivePolicy(
    val evidence: Set<CrumbEvidenceCategory>,
    val reporterFields: Set<CrumbReporterField>,
    val customContext: Map<String, String>,
    val status: CrumbPolicyStatus,
    val workspacePolicyVersion: Int?,
) {
    val hasValidWorkspacePolicy: Boolean
        get() = status == CrumbPolicyStatus.FRESH || status == CrumbPolicyStatus.CACHED
}

object CrumbPolicyEvaluator {
    fun localEvidence(configuration: CrumbConfiguration): Set<CrumbEvidenceCategory> =
        configuration.evidence.toMutableSet().apply {
            if (!configuration.capture.screenshot) remove(CrumbEvidenceCategory.SCREENSHOT)
            if (!configuration.diagnostics.logs.enabled) remove(CrumbEvidenceCategory.LOGS)
            if (configuration.diagnostics.healthCheckUrl == null) remove(CrumbEvidenceCategory.HEALTH_CHECK)
        }

    fun effective(
        configuration: CrumbConfiguration,
        workspacePolicy: CrumbWorkspacePolicy?,
        status: CrumbPolicyStatus,
        nowMillis: Long = System.currentTimeMillis(),
    ): CrumbEffectivePolicy {
        val localEvidence = localEvidence(configuration)
        val localFields = configuration.reporter.visibleFields
        val localContext = if (CrumbEvidenceCategory.CUSTOM_CONTEXT in localEvidence) {
            CrumbCustomContextSanitizer.sanitize(configuration.customContext)
        } else {
            emptyMap()
        }
        if (configuration.workspacePolicy.url == null) {
            return CrumbEffectivePolicy(
                evidence = localEvidence,
                reporterFields = localFields,
                customContext = localContext,
                status = CrumbPolicyStatus.NOT_CONFIGURED,
                workspacePolicyVersion = null,
            )
        }

        val validPolicy = workspacePolicy?.takeIf {
            it.isValidAt(nowMillis) &&
                (status == CrumbPolicyStatus.FRESH || status == CrumbPolicyStatus.CACHED)
        }
            ?: return CrumbEffectivePolicy(
                evidence = emptySet(),
                reporterFields = setOf(CrumbReporterField.DESCRIPTION),
                customContext = emptyMap(),
                status = status,
                workspacePolicyVersion = null,
            )
        val effectiveEvidence = localEvidence - validPolicy.disabledEvidence
        return CrumbEffectivePolicy(
            evidence = effectiveEvidence,
            reporterFields = (localFields - validPolicy.hiddenReporterFields) + CrumbReporterField.DESCRIPTION,
            customContext = if (CrumbEvidenceCategory.CUSTOM_CONTEXT in effectiveEvidence) {
                CrumbCustomContextSanitizer.sanitize(
                    configuration.customContext,
                    allowedByPolicy = validPolicy.allowedContextKeys,
                )
            } else {
                emptyMap()
            },
            status = status,
            workspacePolicyVersion = validPolicy.version,
        )
    }
}

object CrumbCustomContextSanitizer {
    const val maximumKeys = 16
    const val maximumKeyBytes = 64
    const val maximumValueBytes = 512
    const val maximumTotalBytes = 8_192

    private val keyPattern = Regex("^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
    private val sensitiveFragments = listOf(
        "password",
        "passwd",
        "secret",
        "token",
        "authorization",
        "cookie",
        "api_key",
        "apikey",
        "access_key",
        "private_key",
        "card",
        "cvv",
        "cvc",
        "ssn",
        "email",
        "phone",
        "address",
    )

    private val valueReplacements = listOf(
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

    fun isValidKey(value: String): Boolean =
        value.toByteArray(StandardCharsets.UTF_8).size <= maximumKeyBytes && keyPattern.matches(value)

    fun sanitize(
        options: CrumbCustomContextOptions,
        allowedByPolicy: Set<String>? = null,
    ): Map<String, String> {
        val allowed = options.allowedKeys
            .intersect(options.values.keys)
            .let { keys -> allowedByPolicy?.let(keys::intersect) ?: keys }
            .asSequence()
            .filter(::isValidKey)
            .sorted()
        val result = linkedMapOf<String, String>()
        var totalBytes = 0
        for (key in allowed) {
            if (result.size >= maximumKeys) break
            if (sensitiveFragments.any { key.lowercase(Locale.ROOT).contains(it) }) continue
            val sanitized = sanitizeValue(options.values[key].orEmpty())
            if (sanitized.isBlank()) continue
            val bytes = key.toByteArray(StandardCharsets.UTF_8).size +
                sanitized.toByteArray(StandardCharsets.UTF_8).size
            if (totalBytes + bytes > maximumTotalBytes) break
            result[key] = sanitized
            totalBytes += bytes
        }
        return result
    }

    private fun sanitizeValue(value: String): String {
        val sanitized = valueReplacements.fold(value) { result, (pattern, replacement) ->
            result.replace(pattern, replacement)
        }
        val printable = sanitized.map { character ->
            if (character.isISOControl()) ' ' else character
        }.joinToString("").trim()
        if (printable.toByteArray(StandardCharsets.UTF_8).size <= maximumValueBytes) return printable
        var result = printable
        while (result.toByteArray(StandardCharsets.UTF_8).size > maximumValueBytes) {
            result = result.dropLast(1)
        }
        return result
    }
}

data class CrumbPolicyFetchSettings(
    val projectKey: String,
    val url: String,
    val timeoutMillis: Long,
)

object CrumbPolicyCache {
    const val maximumBytes = 65_536

    fun load(value: String?, nowMillis: Long = System.currentTimeMillis()): CrumbWorkspacePolicy? =
        value?.let { runCatching { CrumbWorkspacePolicy.fromJson(it, nowMillis) }.getOrNull() }
}

object CrumbPolicy {
    fun scopeKey(projectKey: String, environment: String, url: String?): String = listOf(
        projectKey,
        environment,
        url.orEmpty(),
    ).joinToString("|") { value ->
        "${value.toByteArray(StandardCharsets.UTF_8).size}:$value"
    }

    fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(Locale.ROOT, byte) }
}

private fun JSONObject.requireString(name: String): String =
    get(name).let { value ->
        value as? String ?: throw CrumbWorkspacePolicyException("$name must be a string")
    }

private fun JSONObject.requireInt(name: String): Int =
    get(name).let { value ->
        if (value !is Number || value.toDouble() % 1.0 != 0.0) {
            throw CrumbWorkspacePolicyException("$name must be an integer")
        }
        value.toLong().let { integer ->
            if (integer !in Int.MIN_VALUE..Int.MAX_VALUE) {
                throw CrumbWorkspacePolicyException("$name is out of range")
            }
            integer.toInt()
        }
    }

private fun <T> JSONObject.enumSet(
    name: String,
    maximum: Int,
    parse: (String) -> T,
): Set<T> = stringSet(name, maximum, parse)

private fun <T> JSONObject.stringSet(
    name: String,
    maximum: Int,
    parse: (String) -> T,
): Set<T> {
    val array = get(name) as? JSONArray
        ?: throw CrumbWorkspacePolicyException("$name must be an array")
    if (array.length() > maximum) throw CrumbWorkspacePolicyException("$name is too large")
    val values = buildList {
        for (index in 0 until array.length()) {
            val raw = array.get(index) as? String
                ?: throw CrumbWorkspacePolicyException("$name values must be strings")
            add(parse(raw))
        }
    }
    if (values.size != values.toSet().size) {
        throw CrumbWorkspacePolicyException("$name contains duplicates")
    }
    return values.toSet()
}
