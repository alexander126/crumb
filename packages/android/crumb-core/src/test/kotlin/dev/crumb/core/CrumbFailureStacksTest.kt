package dev.crumb.core

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CrumbFailureStacksTest {
    @Test fun capturesManagedFramesAndLeavesThreadsRunning() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val worker = Thread { started.countDown(); release.await() }
        worker.name = "worker token=synthetic-secret person@example.com"
        worker.start()
        try {
            assertTrue(started.await(2, TimeUnit.SECONDS))
            val captured = requireNotNull(CrumbFailureStacks.capture())
            assertEquals("managed_threads", captured.scope)
            assertTrue(captured.threads.size >= 2)
            val json = CrumbFailureStacks.encode(captured).toString()
            assertTrue(json.toByteArray().size <= 12_288)
            assertFalse(json.contains("synthetic-secret"))
            assertFalse(json.contains("person@example.com"))
            assertEquals(captured, CrumbFailureStacks.decode(JSONObject(json)))
        } finally { release.countDown(); worker.join(2_000) }
        assertFalse(worker.isAlive)
    }

    @Test fun rejectsOversizedStoredFrames() {
        val data = JSONObject().put("truncated", false).put("threads", org.json.JSONArray().put(
            JSONObject().put("id", 1).put("name", "main").put("state", "waiting")
                .put("frames", org.json.JSONArray().put("x".repeat(513)))))
        assertNull(CrumbFailureStacks.decode(data))
    }
}
