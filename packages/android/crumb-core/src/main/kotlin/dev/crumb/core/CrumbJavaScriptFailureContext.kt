package dev.crumb.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject
import java.io.File

/** Local failure-time metadata; the public envelope still uses its existing diagnostics fields. */
internal data class CrumbJavaScriptFailureContext(
    val capturedAtMillis: Long,
    val processName: String,
    val processId: Int,
    val cpuUsagePercent: Double?,
    val residentMemoryBytes: Long?,
    val threadCount: Int?,
    val thermalState: String,
    val networkStatus: String,
    val networkTransport: String,
    val networkExpensive: Boolean,
    val networkConstrained: Boolean,
    val stacks: CrumbStackTraceDiagnostic? = null,
    val rendering: String? = null,
) {
    fun encode(): JSONObject = JSONObject().apply {
        rendering?.let { put("rendering", JSONObject(it)) }
        stacks?.let { put("stacks", CrumbFailureStacks.encode(it)) }
        put("captured_at_millis", capturedAtMillis)
        put("process_name", processName)
        put("process_id", processId)
        cpuUsagePercent?.let { put("cpu_usage_percent", it) }
        residentMemoryBytes?.let { put("resident_memory_bytes", it) }
        threadCount?.let { put("thread_count", it) }
        put("thermal_state", thermalState)
        put("network_status", networkStatus)
        put("network_transport", networkTransport)
        put("network_expensive", networkExpensive)
        put("network_constrained", networkConstrained)
    }

    fun diagnostics(): CrumbDiagnosticsSnapshot = CrumbDiagnosticsSnapshot(
        capturedAtMillis = capturedAtMillis, location = "react_native_javascript_failure",
        processName = processName, processId = processId,
        cpuUsagePercent = cpuUsagePercent, residentMemoryBytes = residentMemoryBytes,
        physicalFootprintBytes = null, thermalState = thermalState,
        threadCount = threadCount ?: 0, busiestThreads = emptyList(), gpuStatus = "unavailable_on_demand",
        network = CrumbNetworkDiagnostic(networkStatus, networkTransport, null,
            networkExpensive, networkConstrained, null),
        logs = CrumbLogDiagnostic(CrumbLogCaptureStatus.UNAVAILABLE, emptyList(), emptyList(), false, 0, emptyList()),
        rendering = rendering,
        stackTraces = stacks ?: CrumbStackTraceDiagnostic(CrumbStackTraceCaptureStatus.UNAVAILABLE, "none",
            emptyList(), false, "native_stacks_not_captured_during_javascript_failure"),
    )

    companion object {
        fun decode(value: JSONObject?): CrumbJavaScriptFailureContext? = runCatching {
            require(value != null)
            val result = CrumbJavaScriptFailureContext(
                capturedAtMillis = value.getLong("captured_at_millis"),
                processName = value.getString("process_name"), processId = value.getInt("process_id"),
                cpuUsagePercent = if (value.has("cpu_usage_percent")) value.getDouble("cpu_usage_percent") else null,
                residentMemoryBytes = if (value.has("resident_memory_bytes")) value.getLong("resident_memory_bytes") else null,
                threadCount = if (value.has("thread_count")) value.getInt("thread_count") else null,
                thermalState = value.getString("thermal_state"), networkStatus = value.getString("network_status"),
                networkTransport = value.getString("network_transport"),
                networkExpensive = value.getBoolean("network_expensive"),
                networkConstrained = value.getBoolean("network_constrained"),
                rendering = CrumbRenderingEvidence.validate(value.optJSONObject("rendering")?.toString()),
                stacks = CrumbFailureStacks.decode(value.optJSONObject("stacks")),
            )
            require(result.capturedAtMillis > 0 && result.processId > 0)
            require(result.processName.isNotBlank() && result.processName.toByteArray().size <= 128)
            require(result.cpuUsagePercent?.let { it.isFinite() && it >= 0 && it <= 100_000 } != false)
            require(result.residentMemoryBytes?.let { it >= 0 } != false)
            require(result.threadCount?.let { it in 0..10_000 } != false)
            require(result.thermalState in setOf("nominal", "light", "moderate", "severe", "critical", "emergency", "shutdown", "unknown", "unavailable"))
            require(result.networkStatus in setOf("reachable", "unreachable", "limited", "unknown"))
            require(result.networkTransport in setOf("wifi", "cellular", "ethernet", "vpn", "bluetooth", "other", "none", "unknown"))
            result
        }.getOrNull()

        internal fun calculateCpuUsagePercent(cpuMillis: Long, elapsedNanos: Long): Double? {
            if (cpuMillis < 0 || elapsedNanos <= 0) return null
            val elapsedMillis = elapsedNanos / 1_000_000.0
            return (cpuMillis / elapsedMillis * 100.0).takeIf { it.isFinite() && it in 0.0..100_000.0 }
        }

        /** A bounded, on-demand snapshot. No HTTP, app callbacks or ongoing sampler. */
        fun capture(context: Context, settings: CrumbReportSettings): CrumbJavaScriptFailureContext {
            val capturedAt = System.currentTimeMillis()
            val rendering = CrumbRenderingEvidence.snapshot(settings)
            val performance = CrumbEvidenceCategory.PERFORMANCE in settings.evidence
            val status = if (performance) runCatching {
                File("/proc/self/status").bufferedReader().use { reader ->
                    reader.lineSequence().take(128).map { it.take(256) }.toList()
                }
            }.getOrDefault(emptyList()) else emptyList()
            fun statusNumber(name: String): Long? = status.firstOrNull { it.startsWith("$name:") }
                ?.substringAfter(':')?.trim()?.substringBefore(' ')?.toLongOrNull()
            val cpu = if (performance) runCatching {
                val start = SystemClock.elapsedRealtimeNanos()
                val before = Process.getElapsedCpuTime()
                Thread.sleep(20) // One short sample on the opted-in JS error handoff, never in a native signal handler.
                calculateCpuUsagePercent(Process.getElapsedCpuTime() - before, SystemClock.elapsedRealtimeNanos() - start)
            }.getOrNull() else null
            val connectivity = if (CrumbEvidenceCategory.NETWORK in settings.evidence) runCatching {
                val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
                val transport = when {
                    capabilities == null -> "none"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
                    else -> "other"
                }
                val networkStatus = when {
                    capabilities == null -> "unreachable"
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) -> "reachable"
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> "limited"
                    else -> "unreachable"
                }
                NetworkSnapshot(networkStatus, transport, manager.isActiveNetworkMetered,
                    manager.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED)
            }.getOrNull() else null
            val thermal = if (performance && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) runCatching {
                when ((context.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus) {
                    PowerManager.THERMAL_STATUS_NONE -> "nominal"
                    PowerManager.THERMAL_STATUS_LIGHT -> "light"
                    PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                    PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                    PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                    PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                    PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                    else -> "unknown"
                }
            }.getOrDefault("unavailable") else "unavailable"
            return CrumbJavaScriptFailureContext(capturedAt, context.packageName.take(128), Process.myPid(),
                cpu, statusNumber("VmRSS")?.times(1024), statusNumber("Threads")?.toInt(), thermal,
                connectivity?.status ?: "unknown", connectivity?.transport ?: "unknown",
                connectivity?.expensive ?: false, connectivity?.constrained ?: false,
                if (CrumbEvidenceCategory.THREAD_STACKS in settings.evidence) CrumbFailureStacks.capture() else null, rendering)
        }
    }
}

private data class NetworkSnapshot(val status: String, val transport: String, val expensive: Boolean, val constrained: Boolean)
