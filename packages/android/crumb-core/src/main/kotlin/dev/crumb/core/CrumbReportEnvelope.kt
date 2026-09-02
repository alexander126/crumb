package dev.crumb.core

import java.time.Instant
import java.util.UUID

data class CrumbReportRuntime(
    val osVersion: String,
    val deviceFamily: String,
    val locale: String,
    val timezone: String,
)

enum class CrumbScreenshotCaptureState(val wireValue: String) {
    ENABLED("enabled"),
    DISABLED_BY_CONFIGURATION("disabled_by_configuration"),
    DISABLED_BY_POLICY("disabled_by_policy"),
    UNAVAILABLE("unavailable"),
}

enum class CrumbScreenshotMaskingState(val wireValue: String) {
    APPLIED("applied"),
    NOT_APPLICABLE("not_applicable"),
    FAILED("failed"),
}

data class CrumbArtifactManifest(
    val id: String,
    val kind: String,
    val mimeType: String,
    val byteSize: Long,
    val sha256: String,
    val redactionState: String,
    val uploadId: String,
)

data class CrumbReportBuildInput(
    val reportId: String,
    val trigger: CrumbInvocation,
    val triggeredAtMillis: Long,
    val submittedAtMillis: Long,
    val runtime: CrumbReportRuntime,
    val category: String,
    val description: String,
    val diagnostics: CrumbDiagnosticsSnapshot,
    val screenshotCapture: CrumbScreenshotCaptureState,
    val screenshotMasking: CrumbScreenshotMaskingState,
    val artifacts: List<CrumbArtifactManifest> = emptyList(),
    val customContext: Map<String, String> = emptyMap(),
    val policyStatus: CrumbPolicyStatus = CrumbPolicyStatus.NOT_CONFIGURED,
    val workspacePolicyVersion: Int? = null,
)

data class CrumbSerializedReportEnvelope(
    val reportId: String,
    val submittedAtMillis: Long,
    val json: String,
)

sealed class CrumbReportEnvelopeException(message: String) : IllegalArgumentException(message) {
    class InvalidConfiguration : CrumbReportEnvelopeException("configuration metadata is invalid")
    class InvalidReportId : CrumbReportEnvelopeException("reportId is invalid")
    class InvalidTimestampOrder : CrumbReportEnvelopeException("submittedAt must not precede triggeredAt")
    class InvalidRuntime : CrumbReportEnvelopeException("runtime metadata is invalid")
    class InvalidCategory : CrumbReportEnvelopeException("category must contain 1-64 characters")
    class InvalidDescription : CrumbReportEnvelopeException("description must contain 1-4000 characters")
    class TooManyArtifacts : CrumbReportEnvelopeException("a report may contain at most 10 artifacts")
    class InvalidArtifact : CrumbReportEnvelopeException("artifact manifest is invalid")
}

internal object CrumbReportEnvelopeBuilder {
    fun makeReportId(uuid: UUID = UUID.randomUUID()): String =
        "rpt_${uuid.toString().replace("-", "")}"

    fun build(
        settings: CrumbReportSettings,
        input: CrumbReportBuildInput,
    ): CrumbSerializedReportEnvelope {
        validate(settings, input)
        val diagnostics = effectiveDiagnostics(input.diagnostics, settings)
        val category = input.category.trim()
        val description = input.description.trim()
        val screenshotEnabled = settings.capture.screenshot &&
            CrumbEvidenceCategory.SCREENSHOT in settings.evidence
        val screenshotCapture = when {
            !settings.capture.screenshot -> CrumbScreenshotCaptureState.DISABLED_BY_CONFIGURATION
            CrumbEvidenceCategory.SCREENSHOT !in settings.evidence ->
                CrumbScreenshotCaptureState.DISABLED_BY_POLICY
            else -> input.screenshotCapture
        }
        val screenshotMasking = if (screenshotEnabled) {
            input.screenshotMasking
        } else {
            CrumbScreenshotMaskingState.NOT_APPLICABLE
        }
        val artifacts = if (screenshotEnabled) input.artifacts else emptyList()
        val memory = if (
            diagnostics.residentMemoryBytes != null || diagnostics.physicalFootprintBytes != null
        ) {
            obj(
                "resident_bytes" to diagnostics.residentMemoryBytes,
                "physical_footprint_bytes" to diagnostics.physicalFootprintBytes,
            )
        } else {
            null
        }
        val health = diagnostics.network.healthCheck?.let {
            obj(
                "host" to it.host,
                "succeeded" to it.succeeded,
                "status_code" to it.statusCode,
                "latency_ms" to it.latencyMilliseconds,
                "failure" to it.failure,
            )
        }
        val logCapture = when (diagnostics.logs.status) {
            CrumbLogCaptureStatus.DISABLED -> "disabled_by_configuration"
            CrumbLogCaptureStatus.DISABLED_BY_POLICY -> "disabled_by_policy"
            CrumbLogCaptureStatus.UNAVAILABLE -> "unavailable"
            CrumbLogCaptureStatus.CAPTURED,
            CrumbLogCaptureStatus.EMPTY,
            -> "enabled"
        }

        val envelope = obj(
            "schema_version" to "1.0",
            "report_id" to input.reportId,
            "trigger" to input.trigger.name.lowercase(),
            "triggered_at" to instant(input.triggeredAtMillis),
            "submitted_at" to instant(input.submittedAtMillis),
            "release" to obj(
                "platform" to "android",
                "app_version" to settings.release.appVersion,
                "native_build" to settings.release.nativeBuild,
                "js_bundle_version" to settings.release.bundleVersion,
                "environment" to settings.environment,
            ),
            "application" to settings.application.name?.let { obj("name" to it) },
            "sdk" to obj(
                "name" to "crumb-android",
                "version" to CrumbSDKVersion.CURRENT,
                "integration" to "native",
            ),
            "runtime" to obj(
                "os" to "android",
                "os_version" to input.runtime.osVersion,
                "device_family" to input.runtime.deviceFamily,
                "locale" to input.runtime.locale,
                "timezone" to input.runtime.timezone,
            ),
            "user_input" to obj(
                "category" to category.lowercase(),
                "description" to description,
            ),
            "diagnostics" to obj(
                "captured_at" to instant(diagnostics.capturedAtMillis),
                "location" to diagnostics.location,
                "process" to obj(
                    "name" to diagnostics.processName,
                    "id" to diagnostics.processId,
                ),
                "cpu_usage_percent" to diagnostics.cpuUsagePercent.finiteOrNull(),
                "memory" to memory,
                "thermal_state" to diagnostics.thermalState,
                "threads" to obj(
                    "count" to diagnostics.threadCount,
                    "busiest" to diagnostics.busiestThreads.map {
                        obj(
                            "id" to it.id.toString(),
                            "name" to it.name,
                            "state" to it.state,
                            "cpu_usage_percent" to it.cpuUsagePercent.finiteOrNull(),
                        )
                    },
                ),
                "gpu" to obj("status" to "unavailable_on_demand"),
                "network" to obj(
                    "status" to diagnostics.network.status,
                    "transport" to diagnostics.network.transport,
                    "cellular_generation" to normalizeGeneration(diagnostics.network.cellularGeneration),
                    "is_expensive" to diagnostics.network.isExpensive,
                    "is_constrained" to diagnostics.network.isConstrained,
                    "health_check" to health,
                ),
                "logs" to obj(
                    "status" to diagnostics.logs.status.name.lowercase(),
                    "sources" to diagnostics.logs.sources,
                    "entries" to diagnostics.logs.entries.map {
                        obj(
                            "timestamp" to instant(it.timestampMillis),
                            "level" to it.level.name.lowercase(),
                            "source" to it.source,
                            "category" to it.category,
                            "message" to it.message,
                        )
                    },
                    "truncated" to diagnostics.logs.truncated,
                    "dropped_entry_count" to diagnostics.logs.droppedEntryCount,
                    "failures" to diagnostics.logs.failures,
                ),
                "stack_traces" to obj(
                    "status" to diagnostics.stackTraces.status.name.lowercase(),
                    "scope" to diagnostics.stackTraces.scope,
                    "threads" to diagnostics.stackTraces.threads.map {
                        obj(
                            "id" to it.id.toString(),
                            "name" to it.name,
                            "state" to it.state,
                            "frames" to it.frames,
                        )
                    },
                    "truncated" to diagnostics.stackTraces.truncated,
                    "unavailable_reason" to diagnostics.stackTraces.unavailableReason,
                ),
            ),
            "privacy" to obj(
                "screenshot_capture" to screenshotCapture.wireValue,
                "screenshot_masking" to screenshotMasking.wireValue,
                "diagnostics_capture" to "on_demand",
                "log_capture" to logCapture,
                "policy_status" to settings.policyStatus.wireValue,
                "policy_version" to settings.workspacePolicyVersion,
            ),
            "custom_context" to settings.customContext.takeIf { it.isNotEmpty() },
            "artifacts" to artifacts.map {
                obj(
                    "id" to it.id,
                    "kind" to it.kind,
                    "mime_type" to it.mimeType,
                    "byte_size" to it.byteSize,
                    "sha256" to it.sha256,
                    "redaction_state" to it.redactionState,
                    "upload_id" to it.uploadId,
                )
            },
        )

        return CrumbSerializedReportEnvelope(
            reportId = input.reportId,
            submittedAtMillis = input.submittedAtMillis,
            json = JsonValueEncoder.encode(envelope),
        )
    }

    private fun validate(settings: CrumbReportSettings, input: CrumbReportBuildInput) {
        if (
            !settings.environment.hasLength(64) ||
            !settings.release.appVersion.hasLength(64) ||
            !settings.release.nativeBuild.hasLength(64) ||
            settings.release.bundleVersion?.hasLength(128) == false
        ) {
            throw CrumbReportEnvelopeException.InvalidConfiguration()
        }
        if (!input.reportId.matches(Regex("^rpt_[A-Za-z0-9_-]{16,80}$"))) {
            throw CrumbReportEnvelopeException.InvalidReportId()
        }
        if (input.triggeredAtMillis > input.submittedAtMillis) {
            throw CrumbReportEnvelopeException.InvalidTimestampOrder()
        }
        if (
            !input.runtime.osVersion.hasLength(64) ||
            !input.runtime.deviceFamily.hasLength(128) ||
            !input.runtime.locale.hasLength(64) ||
            !input.runtime.timezone.hasLength(128)
        ) {
            throw CrumbReportEnvelopeException.InvalidRuntime()
        }
        if (input.category.trim().length !in 1..64) {
            throw CrumbReportEnvelopeException.InvalidCategory()
        }
        if (input.description.trim().length !in 1..4_000) {
            throw CrumbReportEnvelopeException.InvalidDescription()
        }
        if (input.artifacts.size > 10) {
            throw CrumbReportEnvelopeException.TooManyArtifacts()
        }
        if (input.artifacts.any {
                !it.id.matches(Regex("^art_[A-Za-z0-9_-]{12,80}$")) ||
                    it.kind !in setOf("screenshot", "annotated_screenshot", "other") ||
                    !it.mimeType.hasLength(128) ||
                    it.byteSize !in 0..26_214_400 ||
                    !it.sha256.matches(Regex("^[a-f0-9]{64}$")) ||
                    it.redactionState !in setOf("sanitized", "masked", "not_applicable") ||
                    !it.uploadId.matches(Regex("^upl_[A-Za-z0-9_-]{12,80}$"))
            }
        ) {
            throw CrumbReportEnvelopeException.InvalidArtifact()
        }
    }

    private fun effectiveDiagnostics(
        input: CrumbDiagnosticsSnapshot,
        settings: CrumbReportSettings,
    ): CrumbDiagnosticsSnapshot {
        val performanceEnabled = CrumbEvidenceCategory.PERFORMANCE in settings.evidence
        val networkEnabled = CrumbEvidenceCategory.NETWORK in settings.evidence
        val healthCheckEnabled = networkEnabled &&
            CrumbEvidenceCategory.HEALTH_CHECK in settings.evidence
        val logsEnabled = CrumbEvidenceCategory.LOGS in settings.evidence
        val stacksEnabled = CrumbEvidenceCategory.THREAD_STACKS in settings.evidence
        return CrumbDiagnosticsSnapshot(
            capturedAtMillis = input.capturedAtMillis,
            location = input.location,
            processName = input.processName,
            processId = input.processId,
            cpuUsagePercent = if (performanceEnabled) input.cpuUsagePercent else null,
            residentMemoryBytes = if (performanceEnabled) input.residentMemoryBytes else null,
            physicalFootprintBytes = if (performanceEnabled) input.physicalFootprintBytes else null,
            thermalState = if (performanceEnabled) input.thermalState else "unavailable",
            threadCount = if (performanceEnabled) input.threadCount else 0,
            busiestThreads = if (performanceEnabled) input.busiestThreads else emptyList(),
            gpuStatus = if (performanceEnabled) input.gpuStatus else "unavailable_by_policy",
            network = if (networkEnabled) {
                input.network.copy(
                    healthCheck = if (healthCheckEnabled) input.network.healthCheck else null,
                )
            } else {
                CrumbNetworkDiagnostic(
                    status = "unknown",
                    transport = "unknown",
                    cellularGeneration = null,
                    isExpensive = false,
                    isConstrained = false,
                    healthCheck = null,
                )
            },
            logs = if (logsEnabled) {
                input.logs
            } else {
                CrumbLogDiagnostic(
                    status = if (settings.diagnostics.logs.enabled) {
                        CrumbLogCaptureStatus.DISABLED_BY_POLICY
                    } else {
                        CrumbLogCaptureStatus.DISABLED
                    },
                    sources = emptyList(),
                    entries = emptyList(),
                    truncated = false,
                    droppedEntryCount = 0,
                    failures = emptyList(),
                )
            },
            stackTraces = if (stacksEnabled) {
                input.stackTraces
            } else {
                CrumbStackTraceDiagnostic(
                    status = CrumbStackTraceCaptureStatus.UNAVAILABLE,
                    scope = "none",
                    threads = emptyList(),
                    truncated = false,
                    unavailableReason = "disabled_by_policy",
                )
            },
        )
    }

    private fun String.hasLength(maximum: Int): Boolean = isNotBlank() && length <= maximum

    private fun instant(milliseconds: Long): String = Instant.ofEpochMilli(milliseconds).toString()

    private fun normalizeGeneration(value: String?): String? = when (value?.lowercase()) {
        "2g" -> "2g"
        "3g" -> "3g"
        "4g/lte", "4g_lte" -> "4g_lte"
        "5g" -> "5g"
        null -> null
        else -> "unknown"
    }

    private fun Double?.finiteOrNull(): Double? = this?.takeIf(Double::isFinite)

    private fun obj(vararg values: Pair<String, Any?>): Map<String, Any?> = buildMap {
        values.forEach { (key, value) -> if (value != null) put(key, value) }
    }
}

private object JsonValueEncoder {
    fun encode(value: Any?): String = buildString { appendValue(value) }

    private fun StringBuilder.appendValue(value: Any?) {
        when (value) {
            null -> append("null")
            is String -> appendString(value)
            is Boolean -> append(if (value) "true" else "false")
            is Byte, is Short, is Int, is Long -> append(value.toString())
            is Float -> append(if (value.isFinite()) value.toString() else "null")
            is Double -> append(if (value.isFinite()) value.toString() else "null")
            is Map<*, *> -> {
                append('{')
                value.entries.forEachIndexed { index, entry ->
                    if (index > 0) append(',')
                    appendString(entry.key as String)
                    append(':')
                    appendValue(entry.value)
                }
                append('}')
            }
            is Iterable<*> -> {
                append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) append(',')
                    appendValue(item)
                }
                append(']')
            }
            else -> error("Unsupported JSON value: ${value.javaClass.name}")
        }
    }

    private fun StringBuilder.appendString(value: String) {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) {
                    append("\\u")
                    append(character.code.toString(16).padStart(4, '0'))
                } else {
                    append(character)
                }
            }
        }
        append('"')
    }
}
