package dev.crumb.ui

import dev.crumb.core.CrumbStackTraceCaptureStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedStackCollectorTest {
    @Test
    fun capturesBoundedManagedThreadStacks() {
        val result = ManagedStackCollector.capture()

        assertEquals(CrumbStackTraceCaptureStatus.CAPTURED, result.status)
        assertEquals("managed_threads", result.scope)
        assertTrue(result.threads.isNotEmpty())
        assertTrue(result.threads.size <= 50)
        assertTrue(result.threads.all { it.frames.size <= 40 })
    }
}
