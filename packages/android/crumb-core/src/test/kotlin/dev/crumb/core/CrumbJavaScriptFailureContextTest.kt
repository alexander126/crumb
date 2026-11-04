package dev.crumb.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The failure context stays in crumb-core: the handoff store mutates it on the
 * crash model while degrading a record to fit its budget. This covers the one
 * piece of arithmetic in it, which moved here when the store moved out.
 */
class CrumbJavaScriptFailureContextTest {
    @Test
    fun cpuSampleUsesMillisecondsAndRejectsInvalidIntervals() {
        assertEquals(50.0, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(10, 20_000_000))
        assertEquals(0.0, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(0, 20_000_000))
        assertEquals(null, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(10, 0))
        assertEquals(null, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(-1, 20_000_000))
    }
}
