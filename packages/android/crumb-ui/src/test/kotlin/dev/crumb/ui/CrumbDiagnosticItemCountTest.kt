package dev.crumb.ui

import dev.crumb.core.CrumbDiagnosticsSnapshot
import dev.crumb.core.CrumbHealthCheckDiagnostic
import dev.crumb.core.CrumbLogCaptureStatus
import dev.crumb.core.CrumbLogDiagnostic
import dev.crumb.core.CrumbLogEntry
import dev.crumb.core.CrumbLogLevel
import dev.crumb.core.CrumbNetworkDiagnostic
import dev.crumb.core.CrumbStackTraceCaptureStatus
import dev.crumb.core.CrumbStackTraceDiagnostic
import dev.crumb.core.CrumbThreadDiagnostic
import dev.crumb.core.CrumbThreadStackDiagnostic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CrumbDiagnosticItemCountTest {
    /**
     * The defect this fixes: the count was a constant 22, shown to the user as
     * "Context ready · 22 items" whatever the capture actually contained - and
     * the snapshot it received was annotated UNUSED_PARAMETER.
     */
    @Test
    fun theCountVariesWithTheSnapshot() {
        val full = CrumbEvidenceCounts.diagnosticItemCount(fullSnapshot())
        val empty = CrumbEvidenceCounts.diagnosticItemCount(emptySnapshot())

        assertTrue("a full capture must count more items than an empty one", full > empty)
        assertEquals(15, full)
        assertEquals(2, empty)
    }

    @Test
    fun oneMissingItemLowersTheCountByOne() {
        val full = CrumbEvidenceCounts.diagnosticItemCount(fullSnapshot())

        val withoutRendering = CrumbEvidenceCounts.diagnosticItemCount(
            fullSnapshot(rendering = null),
        )
        val withoutHealthCheck = CrumbEvidenceCounts.diagnosticItemCount(
            fullSnapshot(healthCheck = null),
        )

        assertEquals(full - 1, withoutRendering)
        assertEquals(full - 1, withoutHealthCheck)
    }

    @Test
    fun aCaptureWithNoEvidenceDoesNotClaimEvidence() {
        assertEquals(2, CrumbEvidenceCounts.diagnosticItemCount(emptySnapshot()))
    }

    private fun fullSnapshot(
        rendering: String? = "{\"source\":\"android_frame_metrics\"}",
        healthCheck: CrumbHealthCheckDiagnostic? = CrumbHealthCheckDiagnostic(
            host = "ingestion.example.invalid",
            succeeded = true,
            statusCode = 204,
            latencyMilliseconds = 18,
            failure = null,
        ),
    ) = CrumbDiagnosticsSnapshot(
        capturedAtMillis = 1_700_000_000_000,
        location = "SyntheticActivity",
        processName = "synthetic.app",
        processId = 42,
        cpuUsagePercent = 12.5,
        residentMemoryBytes = 1_024,
        physicalFootprintBytes = 2_048,
        thermalState = "nominal",
        threadCount = 4,
        busiestThreads = listOf(
            CrumbThreadDiagnostic(id = 1, name = "main", state = "running", cpuUsagePercent = 3.0),
        ),
        gpuStatus = "Unavailable on demand on Android",
        network = CrumbNetworkDiagnostic(
            status = "reachable",
            transport = "wifi",
            cellularGeneration = "5G",
            isExpensive = false,
            isConstrained = false,
            healthCheck = healthCheck,
        ),
        logs = CrumbLogDiagnostic(
            status = CrumbLogCaptureStatus.CAPTURED,
            sources = listOf("logcat"),
            entries = listOf(
                CrumbLogEntry(
                    timestampMillis = 1_700_000_000_000,
                    level = CrumbLogLevel.INFO,
                    category = "synthetic",
                    message = "synthetic entry",
                ),
            ),
            truncated = false,
            droppedEntryCount = 0,
            failures = emptyList(),
        ),
        stackTraces = CrumbStackTraceDiagnostic(
            status = CrumbStackTraceCaptureStatus.CAPTURED,
            scope = "managed",
            threads = listOf(
                CrumbThreadStackDiagnostic(
                    id = 1,
                    name = "main",
                    state = "RUNNABLE",
                    frames = listOf("synthetic.Frame.method(Frame.kt:1)"),
                ),
            ),
            truncated = false,
            unavailableReason = null,
        ),
        rendering = rendering,
        screenContext = "{\"name\":\"SyntheticScreen\"}",
    )

    private fun emptySnapshot() = CrumbDiagnosticsSnapshot(
        capturedAtMillis = 1_700_000_000_000,
        location = "SyntheticActivity",
        processName = "synthetic.app",
        processId = 42,
        cpuUsagePercent = null,
        residentMemoryBytes = null,
        physicalFootprintBytes = null,
        thermalState = "unavailable",
        threadCount = 0,
        busiestThreads = emptyList(),
        gpuStatus = "Unavailable on demand on Android",
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
            unavailableReason = "disabled_by_policy",
        ),
        rendering = null,
        screenContext = null,
    )
}
