package dev.crumb.ui

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.telephony.TelephonyManager
import dev.crumb.core.CrumbDiagnosticsOptions
import dev.crumb.core.CrumbDiagnosticsSnapshot
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbLogCaptureStatus
import dev.crumb.core.CrumbLogDiagnostic
import dev.crumb.core.CrumbNetworkDiagnostic
import dev.crumb.core.CrumbStackTraceCaptureStatus
import dev.crumb.core.CrumbStackTraceDiagnostic
import dev.crumb.core.CrumbThreadDiagnostic
import java.io.File

internal object OnDemandDiagnosticsCollector {
    private const val sampleDurationMillis = 200L
    private const val UNAVAILABLE = "unavailable"
    private const val UNKNOWN = "unknown"
    private const val UNKNOWN_PROCESS = "unknown"

    /**
     * Always returns a snapshot. Report submission is gated on diagnostics
     * having arrived, and the collector runs on a bare thread, so an escaping
     * exception would both crash the host process and leave the user unable to
     * save the report they are writing. A source that cannot be read is
     * unavailable evidence, never a failure of the whole capture.
     */
    fun capture(
        context: Context,
        location: String,
        options: CrumbDiagnosticsOptions,
        evidence: Set<CrumbEvidenceCategory> = CrumbEvidenceCategory.entries.toSet(),
        screenContext: String? = null,
        collect: () -> CrumbDiagnosticsSnapshot = {
            collect(context, location, options, evidence, screenContext)
        },
    ): CrumbDiagnosticsSnapshot = runCatching(collect).getOrElse { failure ->
        unavailableSnapshot(context, location, screenContext, evidence, failure)
    }

    private fun collect(
        context: Context,
        location: String,
        options: CrumbDiagnosticsOptions,
        evidence: Set<CrumbEvidenceCategory>,
        screenContext: String?,
    ): CrumbDiagnosticsSnapshot {
        val capturesPerformance = CrumbEvidenceCategory.PERFORMANCE in evidence
        val firstThreads = if (capturesPerformance) readThreads() else emptyMap()
        val firstProcessCpuMillis = if (capturesPerformance) Process.getElapsedCpuTime() else 0L
        val startedAt = SystemClock.elapsedRealtime()
        if (capturesPerformance) Thread.sleep(sampleDurationMillis)
        val elapsedMillis = (SystemClock.elapsedRealtime() - startedAt).coerceAtLeast(1)
        val processCpuMillis = if (capturesPerformance) {
            Process.getElapsedCpuTime() - firstProcessCpuMillis
        } else {
            0L
        }
        val secondThreads = if (capturesPerformance) readThreads() else emptyMap()
        val clockTicks = runCatching { Os.sysconf(OsConstants._SC_CLK_TCK) }.getOrDefault(100L)

        val threads = secondThreads.map { (id, sample) ->
            val previousTicks = firstThreads[id]?.cpuTicks
            val cpu = previousTicks?.let {
                (sample.cpuTicks - it).coerceAtLeast(0).toDouble() / clockTicks.toDouble() /
                    (elapsedMillis.toDouble() / 1_000.0) * 100.0
            }
            CrumbThreadDiagnostic(
                id = id,
                name = sample.name,
                state = threadState(sample.state),
                cpuUsagePercent = cpu,
            )
        }.sortedByDescending { it.cpuUsagePercent ?: 0.0 }

        val memory = if (capturesPerformance) {
            runCatching { Debug.MemoryInfo().also(Debug::getMemoryInfo) }.getOrNull()
        } else {
            null
        }
        return CrumbDiagnosticsSnapshot(
            screenContext = if (CrumbEvidenceCategory.CUSTOM_CONTEXT in evidence) screenContext else null,
            rendering = if (options.renderingEnabled && CrumbEvidenceCategory.PERFORMANCE in evidence) dev.crumb.core.CrumbRenderingEvidence.provider?.invoke(true) else null,
            capturedAtMillis = System.currentTimeMillis(),
            location = location,
            processName = runCatching { processName(context) }.getOrDefault(UNKNOWN_PROCESS),
            processId = Process.myPid(),
            cpuUsagePercent = if (capturesPerformance) {
                processCpuMillis.toDouble() / elapsedMillis.toDouble() * 100.0
            } else {
                null
            },
            residentMemoryBytes = if (capturesPerformance) residentMemoryBytes() else null,
            physicalFootprintBytes = memory?.totalPss?.toLong()?.times(1_024),
            thermalState = if (capturesPerformance) {
                runCatching { thermalState(context) }.getOrDefault(UNAVAILABLE)
            } else {
                UNAVAILABLE
            },
            threadCount = threads.size,
            busiestThreads = threads.take(12),
            gpuStatus = "Unavailable on demand on Android",
            network = if (CrumbEvidenceCategory.NETWORK in evidence) {
                networkDiagnostics(
                    context,
                    options,
                    includeHealthCheck = CrumbEvidenceCategory.HEALTH_CHECK in evidence,
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
            logs = if (CrumbEvidenceCategory.LOGS in evidence) {
                OnDemandLogCollector.capture(options.logs)
            } else {
                CrumbLogDiagnostic(
                    status = if (options.logs.enabled) {
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
            stackTraces = if (CrumbEvidenceCategory.THREAD_STACKS in evidence) {
                ManagedStackCollector.capture()
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

    /**
     * Partial diagnostics for a capture that could not be completed. Evidence is
     * marked unavailable rather than fabricated, and the failure carries a
     * bounded type name only - never an exception message or source content.
     */
    private fun unavailableSnapshot(
        context: Context,
        location: String,
        screenContext: String?,
        evidence: Set<CrumbEvidenceCategory>,
        failure: Throwable,
    ) = CrumbDiagnosticsSnapshot(
        screenContext = if (CrumbEvidenceCategory.CUSTOM_CONTEXT in evidence) screenContext else null,
        rendering = null,
        capturedAtMillis = System.currentTimeMillis(),
        location = location,
        processName = runCatching { context.packageName }.getOrDefault(UNKNOWN_PROCESS),
        processId = Process.myPid(),
        cpuUsagePercent = null,
        residentMemoryBytes = null,
        physicalFootprintBytes = null,
        thermalState = UNAVAILABLE,
        threadCount = 0,
        busiestThreads = emptyList(),
        gpuStatus = "Unavailable on demand on Android",
        network = CrumbNetworkDiagnostic(
            status = UNKNOWN,
            transport = UNKNOWN,
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
            failures = listOf(failureName(failure)),
        ),
        stackTraces = CrumbStackTraceDiagnostic(
            status = CrumbStackTraceCaptureStatus.UNAVAILABLE,
            scope = "none",
            threads = emptyList(),
            truncated = false,
            unavailableReason = failureName(failure),
        ),
    )

    private fun failureName(failure: Throwable): String =
        "collector_failed:" + (failure.javaClass.simpleName.ifEmpty { "Throwable" }).take(64)

    private fun readThreads(): Map<Long, ThreadSample> {
        return File("/proc/self/task").listFiles().orEmpty().mapNotNull { directory ->
            val id = directory.name.toLongOrNull() ?: return@mapNotNull null
            val stat = runCatching { File(directory, "stat").readText() }.getOrNull()
                ?: return@mapNotNull null
            val commandEnd = stat.lastIndexOf(')')
            if (commandEnd < 0 || commandEnd + 2 >= stat.length) return@mapNotNull null
            val commandStart = stat.indexOf('(')
            val fields = stat.substring(commandEnd + 2).trim().split(Regex("\\s+"))
            if (fields.size <= 12) return@mapNotNull null
            val userTicks = fields[11].toLongOrNull() ?: return@mapNotNull null
            val systemTicks = fields[12].toLongOrNull() ?: return@mapNotNull null
            val name = runCatching { File(directory, "comm").readText().trim() }.getOrNull()
                ?.takeIf(String::isNotEmpty)
                ?: stat.substring(commandStart + 1, commandEnd)
            id to ThreadSample(name = name, state = fields[0].firstOrNull(), cpuTicks = userTicks + systemTicks)
        }.toMap()
    }

    private fun residentMemoryBytes(): Long? {
        val status = runCatching { File("/proc/self/status").readLines() }.getOrNull() ?: return null
        val valueKilobytes = status.firstOrNull { it.startsWith("VmRSS:") }
            ?.substringAfter(':')
            ?.trim()
            ?.substringBefore(' ')
            ?.toLongOrNull()
        return valueKilobytes?.times(1_024)
    }

    private fun processName(context: Context): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ApplicationProcessName.value ?: context.packageName
        } else {
            context.packageName
        }
    }

    private fun thermalState(context: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unavailable"
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return when (power.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown"
        }
    }

    private fun networkDiagnostics(
        context: Context,
        options: CrumbDiagnosticsOptions,
        includeHealthCheck: Boolean,
    ): CrumbNetworkDiagnostic {
        // A host can strip the merged ACCESS_NETWORK_STATE permission, and
        // these calls then raise SecurityException. Unknown connectivity is
        // evidence; it must not discard the rest of the snapshot.
        val connectivity = runCatching {
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        }.getOrNull() ?: return unknownNetwork(options, includeHealthCheck)
        val capabilities = runCatching {
            connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        }.getOrElse { return unknownNetwork(options, includeHealthCheck) }
        val transport = when {
            capabilities == null -> "none"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
            else -> "other"
        }
        val status = when {
            capabilities == null -> "unreachable"
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) -> "reachable"
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> "limited"
            else -> "unreachable"
        }
        return CrumbNetworkDiagnostic(
            status = status,
            transport = transport,
            cellularGeneration = if (transport == "cellular") {
                runCatching { cellularGeneration(context) }.getOrNull()
            } else {
                null
            },
            isExpensive = runCatching { connectivity.isActiveNetworkMetered }.getOrDefault(false),
            isConstrained = runCatching {
                connectivity.restrictBackgroundStatus ==
                    ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
            }.getOrDefault(false),
            healthCheck = healthCheck(options, includeHealthCheck),
        )
    }

    private fun unknownNetwork(
        options: CrumbDiagnosticsOptions,
        includeHealthCheck: Boolean,
    ) = CrumbNetworkDiagnostic(
        status = UNKNOWN,
        transport = UNKNOWN,
        cellularGeneration = null,
        isExpensive = false,
        isConstrained = false,
        healthCheck = healthCheck(options, includeHealthCheck),
    )

    private fun healthCheck(options: CrumbDiagnosticsOptions, includeHealthCheck: Boolean) =
        if (includeHealthCheck) {
            options.healthCheckUrl?.let {
                runCatching {
                    CrumbInfrastructureHealthProbe.capture(it, options.timeoutMillis)
                }.getOrNull()
            }
        } else {
            null
        }

    @Suppress("DEPRECATION")
    private fun cellularGeneration(context: Context): String? {
        val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        val networkType = runCatching { telephony.dataNetworkType }.getOrNull() ?: return null
        return when (networkType) {
            TelephonyManager.NETWORK_TYPE_NR -> "5G"
            TelephonyManager.NETWORK_TYPE_LTE -> "4G/LTE"
            TelephonyManager.NETWORK_TYPE_HSPAP,
            TelephonyManager.NETWORK_TYPE_HSPA,
            TelephonyManager.NETWORK_TYPE_HSDPA,
            TelephonyManager.NETWORK_TYPE_HSUPA,
            TelephonyManager.NETWORK_TYPE_UMTS,
            TelephonyManager.NETWORK_TYPE_EVDO_0,
            TelephonyManager.NETWORK_TYPE_EVDO_A,
            TelephonyManager.NETWORK_TYPE_EVDO_B,
            TelephonyManager.NETWORK_TYPE_EHRPD,
            TelephonyManager.NETWORK_TYPE_TD_SCDMA,
            -> "3G"
            TelephonyManager.NETWORK_TYPE_EDGE,
            TelephonyManager.NETWORK_TYPE_GPRS,
            TelephonyManager.NETWORK_TYPE_CDMA,
            TelephonyManager.NETWORK_TYPE_1xRTT,
            TelephonyManager.NETWORK_TYPE_IDEN,
            TelephonyManager.NETWORK_TYPE_GSM,
            -> "2G"
            else -> null
        }
    }

    private fun threadState(state: Char?): String = when (state) {
        'R' -> "running"
        'S' -> "sleeping"
        'D' -> "uninterruptible"
        'T', 't' -> "stopped"
        'Z' -> "zombie"
        'I' -> "idle"
        else -> "unknown"
    }

    private data class ThreadSample(
        val name: String,
        val state: Char?,
        val cpuTicks: Long,
    )

    private object ApplicationProcessName {
        val value: String?
            get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                android.app.Application.getProcessName()
            } else {
                null
            }
    }
}
