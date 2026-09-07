package dev.crumb.core

import android.content.Context
import android.os.Build
import android.os.Process
import java.util.Locale
import java.util.TimeZone

internal object CrumbJavaScriptCrashRecovery {
    fun recover(context: Context, settings: CrumbReportSettings): Boolean {
        val store = CrumbJavaScriptCrashStore(context.noBackupFilesDir.resolve("crumb/javascript-crashes"))
        val pending = store.records()
        if (pending.isEmpty()) return false

        var recovered = false
        pending.forEach { crash ->
            val reportId = recoveryReportId(crash.recordId)
            if (runCatching { CrumbReportQueue.from(context).reports() }
                    .getOrNull()
                    ?.any { it.reportId == reportId } == true
            ) {
                recovered = store.remove(crash.recordId) || recovered
                return@forEach
            }
            val input = recoveryInput(crash, settings)
            runCatching {
                val envelope = CrumbReportEnvelopeBuilder.build(settings, input)
                CrumbReportQueue.from(context).enqueue(envelope, emptyList())
                store.remove(crash.recordId)
            }.onSuccess {
                recovered = true
            }
        }
        return recovered
    }

    internal fun recoveryInput(crash: CrumbJavaScriptCrash, settings: CrumbReportSettings, runtime: CrumbReportRuntime = recoveryRuntime()): CrumbReportBuildInput {
        val release = CrumbRelease(
            appVersion = crash.release.appVersion ?: settings.release.appVersion,
            nativeBuild = crash.release.nativeBuild ?: settings.release.nativeBuild,
            bundleVersion = crash.release.bundleVersion ?: settings.release.bundleVersion,
        )
        val reportCrash = crash.copy(
            release = CrumbJavaScriptCrashRelease(
                appVersion = release.appVersion,
                nativeBuild = release.nativeBuild,
                bundleVersion = release.bundleVersion,
            ),
            breadcrumbs = if (settings.diagnostics.logs.enabled && CrumbEvidenceCategory.LOGS in settings.evidence) crash.breadcrumbs else emptyList(),
            context = if (CrumbEvidenceCategory.CUSTOM_CONTEXT in settings.evidence) {
                crash.context.filterKeys { it in settings.customContext }
            } else {
                emptyMap()
            },
        )
        return CrumbReportBuildInput(
            reportId = recoveryReportId(crash.recordId),
            trigger = CrumbInvocation.PROGRAMMATIC,
            triggeredAtMillis = crash.occurredAt.toEpochMilli(),
            submittedAtMillis = System.currentTimeMillis(),
            runtime = runtime,
            category = "Bug",
            description = "JavaScript ${crash.kind}: ${crash.message}".take(4_000),
            diagnostics = crash.failureContext?.diagnostics() ?: recoveryDiagnostics(),
            screenshotCapture = CrumbScreenshotCaptureState.DISABLED_BY_CONFIGURATION,
            screenshotMasking = CrumbScreenshotMaskingState.NOT_APPLICABLE,
            customContext = settings.customContext,
            policyStatus = settings.policyStatus,
            workspacePolicyVersion = settings.workspacePolicyVersion,
            javascriptCrash = reportCrash,
        )
    }

    private fun recoveryReportId(recordId: String): String = "rpt_${recordId.drop(4)}"

    private fun recoveryRuntime(): CrumbReportRuntime {
        val deviceFamily = listOf(Build.MANUFACTURER, Build.MODEL)
            .filter(String::isNotBlank)
            .joinToString(" ")
            .ifBlank { "Android device" }
            .take(128)
        return CrumbReportRuntime(
            osVersion = "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})".take(64),
            deviceFamily = deviceFamily,
            locale = Locale.getDefault().toLanguageTag().ifBlank { "und" }.take(64),
            timezone = TimeZone.getDefault().id.take(128),
        )
    }

    private fun recoveryDiagnostics(): CrumbDiagnosticsSnapshot = CrumbDiagnosticsSnapshot(
        capturedAtMillis = System.currentTimeMillis(),
        location = "react_native_recovery",
        processName = "react-native",
        processId = Process.myPid(),
        cpuUsagePercent = null,
        residentMemoryBytes = null,
        physicalFootprintBytes = null,
        thermalState = "unavailable",
        threadCount = 0,
        busiestThreads = emptyList(),
        gpuStatus = "unavailable",
        network = CrumbNetworkDiagnostic(
            status = "unknown",
            transport = "unknown",
            cellularGeneration = null,
            isExpensive = false,
            isConstrained = false,
            healthCheck = null,
        ),
        logs = CrumbLogDiagnostic(
            status = CrumbLogCaptureStatus.UNAVAILABLE,
            sources = emptyList(),
            entries = emptyList(),
            truncated = false,
            droppedEntryCount = 0,
            failures = emptyList(),
        ),
        stackTraces = CrumbStackTraceDiagnostic(
            status = CrumbStackTraceCaptureStatus.UNAVAILABLE,
            scope = "none",
            threads = emptyList(),
            truncated = false,
            unavailableReason = "unavailable_during_recovery",
        ),
    )
}
