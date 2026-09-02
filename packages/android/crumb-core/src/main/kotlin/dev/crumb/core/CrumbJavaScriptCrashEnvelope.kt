package dev.crumb.core

import java.time.Instant

internal object CrumbJavaScriptCrashEnvelopeBuilder {
    fun build(
        settings: CrumbReportSettings,
        record: CrumbJavaScriptCrashRecord,
        runtime: CrumbJavaScriptCrashRuntime,
    ): CrumbSerializedReportEnvelope {
        val crash = record.crash
        val customContext = record.customContext.filter { (key, value) ->
            settings.customContext[key] == value
        }
        val envelope = obj(
            "schema_version" to "1.0",
            "report_id" to record.reportId,
            "trigger" to "javascript_crash",
            "triggered_at" to instant(crash.occurredAtMillis),
            "submitted_at" to instant(crash.occurredAtMillis),
            "release" to obj(
                "platform" to "react_native",
                "app_version" to record.appVersion,
                "native_build" to record.nativeBuild,
                "js_bundle_version" to record.bundleVersion,
                "environment" to record.environment,
            ),
            "application" to record.applicationName?.let { obj("name" to it) },
            "sdk" to obj(
                "name" to "crumb-react-native",
                "version" to CrumbSDKVersion.CURRENT,
                "integration" to "react_native",
            ),
            "runtime" to obj(
                "os" to "android",
                "os_version" to runtime.osVersion,
                "device_family" to runtime.deviceFamily,
                "locale" to runtime.locale,
                "timezone" to runtime.timezone,
            ),
            "user_input" to obj(
                "category" to "javascript_crash",
                "description" to CrumbJavaScriptCrashSanitizer.truncateUtf8(
                    "${crash.errorType}: ${crash.message}",
                    4_000,
                ),
            ),
            "javascript_crash" to obj(
                "source" to crash.source.wireValue,
                "kind" to crash.kind.wireValue,
                "error_type" to crash.errorType,
                "message" to crash.message,
                "raw_stack" to crash.rawStack,
                "deduplication_key" to (crash.fingerprint ?: "js_unknown"),
                "native_termination_wrapper" to crash.nativeTerminationWrapper,
                "breadcrumbs" to crash.breadcrumbs.map { breadcrumb ->
                    obj(
                        "timestamp" to instant(breadcrumb.timestampMillis),
                        "category" to breadcrumb.category,
                        "message" to breadcrumb.message,
                    )
                },
            ),
            "diagnostics" to obj(
                "captured_at" to instant(crash.occurredAtMillis),
                "location" to "javascript_crash_recovery",
                "process" to obj(
                    "name" to runtime.processName,
                    "id" to runtime.processId,
                ),
                "thermal_state" to "unavailable",
                "threads" to obj(
                    "count" to 0,
                    "busiest" to emptyList<Any>(),
                ),
                "gpu" to obj("status" to "unavailable_on_demand"),
                "network" to obj(
                    "status" to "unknown",
                    "transport" to "unknown",
                    "is_expensive" to false,
                    "is_constrained" to false,
                ),
                "logs" to obj(
                    "status" to "unavailable",
                    "sources" to emptyList<String>(),
                    "entries" to emptyList<Any>(),
                    "truncated" to false,
                    "dropped_entry_count" to 0,
                    "failures" to listOf("crash_recovery"),
                ),
                "stack_traces" to obj(
                    "status" to "unavailable",
                    "scope" to "none",
                    "threads" to emptyList<Any>(),
                    "truncated" to false,
                    "unavailable_reason" to "crash_recovery",
                ),
            ),
            "privacy" to obj(
                "screenshot_capture" to "not_applicable",
                "screenshot_masking" to "not_applicable",
                "diagnostics_capture" to "crash_recovery",
                "log_capture" to "not_applicable",
                "policy_status" to settings.policyStatus.wireValue,
                "policy_version" to settings.workspacePolicyVersion,
            ),
            "custom_context" to customContext.takeIf { it.isNotEmpty() },
            "artifacts" to emptyList<Any>(),
        )
        return CrumbSerializedReportEnvelope(
            reportId = record.reportId,
            submittedAtMillis = crash.occurredAtMillis,
            json = JsonValueEncoder.encode(envelope),
        )
    }

    private fun instant(milliseconds: Long): String = Instant.ofEpochMilli(milliseconds).toString()

    private fun obj(vararg values: Pair<String, Any?>): Map<String, Any?> = linkedMapOf<String, Any?>().apply {
        values.forEach { (key, value) -> if (value != null) put(key, value) }
    }
}

internal object CrumbJavaScriptCrashRecovery {
    fun recoverPending(
        store: CrumbJavaScriptCrashStore,
        queue: CrumbReportQueue,
        settings: CrumbReportSettings,
        runtime: CrumbJavaScriptCrashRuntime,
    ): Int {
        val queuedIds = runCatching { queue.reports().map { it.reportId }.toSet() }
            .getOrNull() ?: return 0
        var recovered = 0
        for (record in store.records()) {
            if (record.reportId in queuedIds) {
                if (store.remove(record.reportId)) recovered += 1
                continue
            }
            val envelope = runCatching {
                CrumbJavaScriptCrashEnvelopeBuilder.build(settings, record, runtime)
            }.getOrNull() ?: continue
            try {
                queue.enqueue(envelope, emptyList())
                if (store.remove(record.reportId)) recovered += 1
            } catch (_: CrumbReportQueueException.QueueFull) {
                break
            } catch (_: Exception) {
                // Keep the pending handoff when storage is unavailable or corrupt.
            }
        }
        return recovered
    }
}
