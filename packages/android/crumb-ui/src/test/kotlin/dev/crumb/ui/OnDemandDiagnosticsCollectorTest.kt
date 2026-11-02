package dev.crumb.ui

import android.content.Context
import dev.crumb.core.CrumbDiagnosticsOptions
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbLogCaptureStatus
import dev.crumb.core.CrumbStackTraceCaptureStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class OnDemandDiagnosticsCollectorTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    /**
     * The defect this fixes: collection ran on a bare thread, so a
     * SecurityException from a connectivity source - which a host can cause by
     * removing the merged ACCESS_NETWORK_STATE permission - reached the default
     * uncaught handler and crashed the host process.
     */
    @Test
    fun aThrowingCollectionYieldsUnavailableEvidenceInsteadOfPropagating() {
        val snapshot = OnDemandDiagnosticsCollector.capture(
            context = context,
            location = "SyntheticActivity",
            options = CrumbDiagnosticsOptions(),
            evidence = CrumbEvidenceCategory.entries.toSet(),
            screenContext = null,
            collect = { throw SecurityException("synthetic permission failure") },
        )

        assertEquals("SyntheticActivity", snapshot.location)
        assertNull(snapshot.cpuUsagePercent)
        assertNull(snapshot.residentMemoryBytes)
        assertNull(snapshot.physicalFootprintBytes)
        assertEquals("unavailable", snapshot.thermalState)
        assertEquals("unknown", snapshot.network.status)
        assertEquals("unknown", snapshot.network.transport)
        assertNull(snapshot.network.healthCheck)
        assertEquals(CrumbLogCaptureStatus.UNAVAILABLE, snapshot.logs.status)
        assertEquals(
            CrumbStackTraceCaptureStatus.UNAVAILABLE,
            snapshot.stackTraces.status,
        )
        assertTrue(snapshot.busiestThreads.isEmpty())
    }

    /** The reporter gates saving on a snapshot existing, so one must exist. */
    @Test
    fun aThrowingCollectionStillProducesASnapshotTheReporterCanSave() {
        val snapshot = OnDemandDiagnosticsCollector.capture(
            context = context,
            location = "SyntheticActivity",
            options = CrumbDiagnosticsOptions(),
            collect = { throw IllegalStateException("synthetic failure") },
        )

        assertNotNull(snapshot)
        assertTrue(snapshot.capturedAtMillis > 0)
        assertTrue(snapshot.processName.isNotEmpty())
    }

    @Test
    fun failureEvidenceCarriesABoundedTypeNameAndNoMessage() {
        val snapshot = OnDemandDiagnosticsCollector.capture(
            context = context,
            location = "SyntheticActivity",
            options = CrumbDiagnosticsOptions(),
            collect = { throw SecurityException("synthetic-secret-detail") },
        )

        assertEquals(listOf("collector_failed:SecurityException"), snapshot.logs.failures)
        assertEquals("collector_failed:SecurityException", snapshot.stackTraces.unavailableReason)
        assertFalse(snapshot.logs.failures.any { it.contains("synthetic-secret-detail") })
    }

    @Test
    fun aSuccessfulCaptureStillCollectsEvidence() {
        val snapshot = OnDemandDiagnosticsCollector.capture(
            context = context,
            location = "SyntheticActivity",
            options = CrumbDiagnosticsOptions(),
            evidence = setOf(CrumbEvidenceCategory.PERFORMANCE, CrumbEvidenceCategory.NETWORK),
        )

        assertEquals("SyntheticActivity", snapshot.location)
        assertNotNull(snapshot.cpuUsagePercent)
        assertTrue(snapshot.logs.failures.isEmpty())
        assertFalse(snapshot.stackTraces.unavailableReason.orEmpty().startsWith("collector_failed"))
        // Thread sampling reads /proc/self/task, which exists only on a Linux
        // host, so the count itself is not asserted here.
    }
}
