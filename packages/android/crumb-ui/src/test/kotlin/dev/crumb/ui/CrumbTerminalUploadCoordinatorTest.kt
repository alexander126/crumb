package dev.crumb.ui

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.os.Looper
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbReportQueue
import dev.crumb.core.CrumbReportUploadWorker
import dev.crumb.core.CrumbSerializedReportEnvelope
import dev.crumb.core.CrumbUploadHttpRequest
import dev.crumb.core.CrumbUploadHttpResponse
import dev.crumb.core.CrumbUploadOptions
import dev.crumb.core.CrumbUploadSettings
import dev.crumb.core.CrumbUploadTransport
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
class CrumbTerminalUploadCoordinatorTest {
    private lateinit var application: Application
    private lateinit var queue: CrumbReportQueue
    private lateinit var transport: TerminalTransport
    private val terminalId = "rpt_TerminalAAAAAAAAAAAAAAAAAAAAAAAAA"
    private val transientId = "rpt_TransientBBBBBBBBBBBBBBBBBBBBBBBB"
    private val newId = "rpt_NewCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"

    @Before
    fun installSyntheticWorker() {
        resetRuntime()
        application = RuntimeEnvironment.getApplication()
        Crumb.start(CrumbConfiguration(
            projectKey = "synthetic-coordinator-key", environment = "test",
            release = CrumbRelease(appVersion = "1", nativeBuild = "1"),
            invocation = setOf(CrumbInvocation.PROGRAMMATIC), evidence = emptySet(),
            upload = CrumbUploadOptions(ingestionUrl = "https://ingestion.example.invalid"),
        ))
        queue = CrumbReportQueue.from(application)
        queue.reports().forEach { queue.remove(it.reportId) }
        transport = TerminalTransport()
        val worker = CrumbReportUploadWorker::class.java.getDeclaredConstructor(
            CrumbReportQueue::class.java, CrumbUploadSettings::class.java, CrumbUploadTransport::class.java,
        ).newInstance(queue, checkNotNull(Crumb.uploadSettings()), transport)
        setField("application", application)
        setField("worker", worker)
        enqueue(terminalId, 0)
    }

    @After
    fun stopDelivery() {
        transport.release.countDown()
        CrumbUploadCoordinator.pause()
        awaitIdle()
        queue.reports().forEach { queue.remove(it.reportId) }
        setField("application", null)
        setField("worker", null)
        resetRuntime()
    }

    @Test
    fun automaticWakesRemainTerminalButLaterForegroundRearms() {
        CrumbUploadCoordinator.resume(application)
        awaitIdle()
        val failed = queue.load(terminalId)
        assertEquals(1, failed.summary.attemptCount)

        CrumbUploadCoordinator.resume(application)
        awaitIdle()
        assertEquals(1, transport.attempts(terminalId))
        enqueue(newId, 2)
        CrumbUploadCoordinator.reportDidQueue()
        awaitIdle()
        assertEquals(1, transport.attempts(newId))
        assertEquals(failed.summary, queue.load(terminalId).summary)
        assertEquals(1, queue.reports().size)

        CrumbUploadCoordinator.pause()
        CrumbUploadCoordinator.reportDidQueue()
        assertFalse(running())
        CrumbUploadCoordinator.resume(application)
        awaitIdle()
        assertEquals(2, transport.attempts(terminalId))
        assertEquals(2, queue.load(terminalId).summary.attemptCount)
        CrumbUploadCoordinator.resume(application)
        awaitIdle()
        assertEquals(2, transport.attempts(terminalId))
    }

    @Test
    fun foregroundIntentWaitsForOldCancelledPass() {
        transport.blocksTransient = true
        enqueue(transientId, 1)
        CrumbUploadCoordinator.resume(application)
        assertTrue(transport.started.await(3, TimeUnit.SECONDS))
        assertEquals(1, transport.attempts(terminalId))

        CrumbUploadCoordinator.pause()
        CrumbUploadCoordinator.resume(application)
        CrumbUploadCoordinator.resume(application)
        CrumbUploadCoordinator.reportDidQueue()
        transport.release.countDown()
        awaitIdle()

        assertEquals(2, transport.attempts(terminalId))
        assertEquals(2, transport.attempts(transientId))
        assertEquals(2, queue.load(terminalId).summary.attemptCount)
        assertEquals(2, queue.load(transientId).summary.attemptCount)
    }

    @Test
    fun retiredConnectivitySignalCannotRestartQuiescentTerminalQueue() {
        CrumbUploadCoordinator.resume(application)
        val retired = checkNotNull(field("networkCallback") as? ConnectivityManager.NetworkCallback)
        // Capture the callback before worker completion retires its registration.
        awaitCondition(pumpMain = false) { !shadowOf(Looper.getMainLooper()).isIdle }
        awaitIdle()
        assertNull(field("networkCallback"))
        retired.onAvailable(network())
        shadowOf(Looper.getMainLooper()).idle()
        assertFalse(running())
        assertNull(field("networkCallback"))
        assertEquals(1, transport.attempts(terminalId))
        assertEquals(1, queue.load(terminalId).summary.attemptCount)
    }

    @Test
    fun connectivityWakeDoesNotRearmTerminalSibling() {
        transport.blocksTransient = true
        enqueue(transientId, 1)
        CrumbUploadCoordinator.resume(application)
        assertTrue(transport.started.await(3, TimeUnit.SECONDS))
        val callback = checkNotNull(field("networkCallback") as? ConnectivityManager.NetworkCallback)
        callback.onAvailable(network())
        shadowOf(Looper.getMainLooper()).idle()
        transport.release.countDown()
        awaitIdle()
        assertEquals(1, transport.attempts(terminalId))
        assertEquals(2, transport.attempts(transientId))
        assertEquals(1, queue.load(terminalId).summary.attemptCount)
    }

    private fun enqueue(id: String, offset: Long) {
        queue.enqueue(CrumbSerializedReportEnvelope(id, 1_700_000_000_000 + offset,
            """{"schema_version":"1.0","report_id":"$id","artifacts":[]}"""), emptyList())
    }

    private fun awaitIdle() = awaitCondition { !running() }
    private fun network(): Network = Network::class.java.getDeclaredConstructor(Int::class.javaPrimitiveType).apply {
        isAccessible = true
    }.newInstance(17)
    private fun running() = field("running") as Boolean
    private fun field(name: String): Any? = CrumbUploadCoordinator::class.java.getDeclaredField(name).apply {
        isAccessible = true
    }.get(CrumbUploadCoordinator)
    private fun setField(name: String, value: Any?) = CrumbUploadCoordinator::class.java.getDeclaredField(name).apply {
        isAccessible = true
    }.set(CrumbUploadCoordinator, value)
    private fun resetRuntime() {
        Crumb::class.java.declaredMethods.single { it.name.startsWith("resetForTesting") }.apply {
            isAccessible = true
        }.invoke(Crumb)
    }

    private fun awaitCondition(pumpMain: Boolean = true, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (!condition() && System.nanoTime() < deadline) {
            if (pumpMain) shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        }
        assertTrue("Timed out waiting for coordinator", condition())
    }

    private inner class TerminalTransport : CrumbUploadTransport {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        var blocksTransient = false
        private val counts = ConcurrentHashMap<String, Int>()
        fun attempts(id: String) = counts[id] ?: 0

        override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse {
            if (!request.url.endsWith("/init")) return CrumbUploadHttpResponse(200, """{"status":"accepted"}""".toByteArray())
            val id = JSONObject(String(checkNotNull(request.body))).getJSONObject("envelope").getString("report_id")
            counts.compute(id) { _, previous -> (previous ?: 0) + 1 }
            if (id == terminalId) return CrumbUploadHttpResponse(422)
            if (id == transientId) {
                if (blocksTransient && attempts(id) == 1) {
                    started.countDown()
                    check(release.await(3, TimeUnit.SECONDS)) { "Synthetic fixture was not released" }
                }
                return CrumbUploadHttpResponse(503)
            }
            return CrumbUploadHttpResponse(200, """{"report_id":"$id","status":"accepted","artifacts":[]}""".toByteArray())
        }
    }
}
