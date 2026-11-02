package dev.crumb.ui

import dev.crumb.core.CrumbDiagnosticsSnapshot

/**
 * Counts the reporter shows the user.
 *
 * They have to be derived from the capture that actually happened: the reporter
 * tells the user what the report contains, and a constant there states
 * something the SDK never measured.
 *
 * Free of the Android framework so the rules are unit-testable without a
 * Robolectric environment.
 */
internal object CrumbEvidenceCounts {
    /**
     * Diagnostic items this snapshot carries, shown as "Context ready - N
     * items". Location and process identity are always present; everything else
     * counts only when it was collected.
     */
    @JvmSynthetic
    fun diagnosticItemCount(diagnostics: CrumbDiagnosticsSnapshot): Int {
        var count = 2 // Capture location and process identity.
        if (diagnostics.cpuUsagePercent != null) count += 1
        if (diagnostics.residentMemoryBytes != null) count += 1
        if (diagnostics.physicalFootprintBytes != null) count += 1
        if (diagnostics.thermalState != "unavailable") count += 1
        if (diagnostics.threadCount > 0) count += 1
        if (diagnostics.busiestThreads.isNotEmpty()) count += 1
        if (diagnostics.network.status != "unknown") count += 1
        if (diagnostics.network.cellularGeneration != null) count += 1
        if (diagnostics.network.healthCheck != null) count += 1
        if (diagnostics.logs.entries.isNotEmpty()) count += 1
        if (diagnostics.stackTraces.threads.isNotEmpty()) count += 1
        if (diagnostics.rendering != null) count += 1
        if (diagnostics.screenContext != null) count += 1
        return count
    }
}
