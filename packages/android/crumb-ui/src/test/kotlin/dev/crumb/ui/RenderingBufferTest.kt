package dev.crumb.ui
import org.junit.Assert.*
import org.junit.Test

class RenderingBufferTest {
    @Test fun retainsOnlyRecentNumericFramesAndDistinguishesMissingGpuFromZero() {
        val buffer = RenderingBuffer()
        assertNull(buffer.snapshot(10000))
        buffer.record(10000, 16.0, 16.0, null)
        buffer.record(10100, 64.0, 16.0, 0.0)
        val snapshot = requireNotNull(buffer.snapshot(10200))
        assertEquals(2, snapshot.sampleCount); assertEquals(1, snapshot.slowFrameCount)
        assertEquals(40.0, snapshot.meanFrameMs, 0.001); assertEquals(1, snapshot.gpuSampleCount)
        assertEquals(0.0, snapshot.meanGpuMs!!, 0.001)
        assertNull(buffer.snapshot(15200))
        buffer.clear(); assertNull(buffer.snapshot(10300))
    }
    @Test fun boundsSamplesAndDropsInvalidDurations() {
        val buffer = RenderingBuffer()
        repeat(2000) { buffer.record(10000, 8.0, 8.0, null) }
        buffer.record(10000, Double.NaN, 8.0, null)
        assertEquals(1000, requireNotNull(buffer.snapshot(10000)).sampleCount)
    }
}
