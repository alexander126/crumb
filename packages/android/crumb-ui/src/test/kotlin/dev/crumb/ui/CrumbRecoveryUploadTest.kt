package dev.crumb.ui

import android.app.Activity
import android.os.Looper
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbReportQueue
import dev.crumb.core.CrumbSerializedReportEnvelope
import dev.crumb.core.CrumbUploadOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.Before
import org.junit.After
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.net.ServerSocket
import java.net.SocketException
import kotlin.concurrent.thread
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import org.robolectric.android.controller.ActivityController

@RunWith(RobolectricTestRunner::class)
class CrumbRecoveryUploadTest {
    private lateinit var host: ActivityController<Activity>
    @Before
    fun resetProcessState() {
        // Robolectric replaces Application between tests, but Kotlin SDK singletons survive.
        Crumb::class.java.declaredMethods.single { it.name.startsWith("resetForTesting") }.apply {
            isAccessible = true
        }.invoke(Crumb)
        resetField(CrumbReporter, "installedApplication", null)
        resetField(CrumbReporter, "lifecycleCallbacks", null)
        resetField(CrumbUploadCoordinator, "application", null)
        resetField(CrumbUploadCoordinator, "worker", null)
        resetField(CrumbWorkspacePolicyCoordinator, "application", null)
    }

    @After
    fun stopDelivery() {
        CrumbUploadCoordinator.pause()
        awaitCondition {
            CrumbUploadCoordinator::class.java.getDeclaredField("running").apply {
                isAccessible = true
            }.getBoolean(CrumbUploadCoordinator).not()
        }
        resetProcessState()
    }

    private fun resetField(target: Any, name: String, value: Any?) {
        target::class.java.getDeclaredField(name).apply { isAccessible = true }.set(target, value)
    }

    @Test
    fun installingIntoResumedActivityUploadsPendingReportWithoutAnotherResume() =
        withUpload { activity, queue, completions ->
            enqueue(queue)
            assertTrue(CrumbReporter.install(activity.application, activity))
            awaitUpload(queue, completions)
        }

    @Test
    fun recoveryAfterEmptyUploadPassWakesUploader() = withUpload { activity, queue, completions ->
        assertTrue(CrumbReporter.install(activity.application, activity))
        awaitCondition(pumpMain = false) { !shadowOf(Looper.getMainLooper()).isIdle }
        shadowOf(Looper.getMainLooper()).idle()
        recordCrash(activity)
        assertTrue(recover(activity))
        awaitUpload(queue, completions)
    }

    @Test
    fun queueNotificationBeforeEmptyPassCompletionIsNotLost() = withUpload { activity, queue, completions ->
        assertTrue(CrumbReporter.install(activity.application, activity))
        // The empty worker has finished; leave its completion callback queued on main.
        awaitCondition(pumpMain = false) { !shadowOf(Looper.getMainLooper()).isIdle }
        enqueue(queue)
        CrumbUploadCoordinator.reportDidQueue()
        awaitUpload(queue, completions)
    }

    @Test
    fun lateInstallationCanAttachTheResumedHost() = withUpload { activity, queue, completions ->
        assertTrue(CrumbReporter.install(activity.application))
        recordCrash(activity)
        assertTrue(recover(activity))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, completions.get())
        assertTrue(CrumbReporter.install(activity.application, activity))
        awaitUpload(queue, completions)
    }

    @Test
    fun backgroundRecoveryStaysPendingUntilResume() = withUpload { activity, queue, completions ->
        assertTrue(CrumbReporter.install(activity.application, activity))
        awaitCondition(pumpMain = false) { !shadowOf(Looper.getMainLooper()).isIdle }
        shadowOf(Looper.getMainLooper()).idle()
        host.pause()
        recordCrash(activity)
        assertTrue(recover(activity))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, completions.get())
        assertEquals(0, queue.reports().single().attemptCount)
        host.resume()
        awaitUpload(queue, completions)
    }

    @Test
    fun recoveryWithoutUploadConfigurationRemainsLocal() = withUpload(uploadEnabled = false) { activity, queue, completions ->
        assertTrue(CrumbReporter.install(activity.application, activity))
        recordCrash(activity)
        assertTrue(recover(activity))
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(0, completions.get())
        assertEquals(0, queue.reports().single().attemptCount)
        assertFalse(recover(activity))
        assertEquals(1, queue.reports().size)
    }

    @Test
    fun repeatedWakeNotificationsDoNotDuplicateTheReport() = withUpload { activity, queue, completions ->
        enqueue(queue)
        assertTrue(CrumbReporter.install(activity.application, activity))
        repeat(3) { CrumbUploadCoordinator.reportDidQueue() }
        awaitUpload(queue, completions)
        CrumbUploadCoordinator.reportDidQueue()
        awaitCondition(pumpMain = false) { !shadowOf(Looper.getMainLooper()).isIdle }
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(1, completions.get())
    }

    private val reportId = "rpt_RecoveryAAAAAAAAAAAAAAAAAAAAAAAA"

    private fun enqueue(queue: CrumbReportQueue) {
        queue.enqueue(CrumbSerializedReportEnvelope(
            reportId, System.currentTimeMillis(),
            """{"schema_version":"1.0","report_id":"$reportId","artifacts":[]}""",
        ), emptyList())
    }

    private fun recover(activity: Activity): Boolean = CompletableFuture.supplyAsync {
        CrumbReporter.recoverJavaScriptCrashes(activity)
    }.get(3, TimeUnit.SECONDS)

    private fun recordCrash(activity: Activity) {
        Crumb.recordJavaScriptCrash(activity, """{
          "schema_version":"1.0", "record_id":"jsc_RecoveryAAAAAAAAAAAAAAAAAAAAAAAA",
          "fingerprint":"0123456789abcdef", "source":"javascript", "kind":"exception",
          "type":"Error", "message":"Synthetic recovery failure", "stack":"at fixture (bundle.js:1:1)",
          "occurred_at":"2026-09-08T00:00:00Z", "release":{"app_version":"1","native_build":"1"},
          "breadcrumbs":[], "context":{}, "is_fatal":true, "native_termination_wrapper_observed":false
        }""")
    }

    private fun awaitUpload(queue: CrumbReportQueue, completions: AtomicInteger) {
        awaitCondition { completions.get() == 1 && queue.reports().isEmpty() }
        assertEquals("Upload must finish while the original activity stays resumed", 1, completions.get())
        assertTrue(queue.reports().isEmpty())
    }

    private fun awaitCondition(pumpMain: Boolean = true, condition: () -> Boolean) {
        val deadline = System.nanoTime() + 3_000_000_000L
        while (System.nanoTime() < deadline && !condition()) {
            if (pumpMain) shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        assertTrue("Timed out waiting for upload lifecycle condition", condition())
    }

    private fun withUpload(uploadEnabled: Boolean = true, block: (Activity, CrumbReportQueue, AtomicInteger) -> Unit) {
        val completions = AtomicInteger()
        val server = ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))
        val serverThread = thread(isDaemon = true, name = "synthetic-ingestion") {
            try {
                while (!server.isClosed) server.accept().use { socket ->
                    val input = socket.getInputStream().bufferedReader()
                    val request = requireNotNull(input.readLine())
                    var length = 0
                    while (true) {
                        val header = input.readLine() ?: break
                        if (header.isEmpty()) break
                        if (header.startsWith("Content-Length:", ignoreCase = true)) {
                            length = header.substringAfter(':').trim().toInt()
                        }
                    }
                    repeat(length) { input.read() }
                    val body = if (request.contains("/init ")) {
                        """{"report_id":"$reportId","status":"initialized","artifacts":[]}"""
                    } else {
                        completions.incrementAndGet()
                        "{}"
                    }
                    socket.getOutputStream().write(
                        ("HTTP/1.1 200 OK\r\nContent-Length: ${body.toByteArray().size}\r\nConnection: close\r\n\r\n" + body).toByteArray(),
                    )
                }
            } catch (_: SocketException) {
                // Closing the fixture ends accept().
            }
        }
        val controller = Robolectric.buildActivity(Activity::class.java).setup().visible()
        host = controller
        val activity = controller.get()
        val queue = CrumbReportQueue.from(activity)
        try {
            Crumb.start(CrumbConfiguration(
                projectKey = "synthetic-recovery-key",
                environment = "test",
                release = CrumbRelease(appVersion = "1", nativeBuild = "1"),
                invocation = setOf(CrumbInvocation.PROGRAMMATIC),
                diagnostics = dev.crumb.core.CrumbDiagnosticsOptions(javascriptCrashCaptureEnabled = true),
                evidence = emptySet(),
                upload = CrumbUploadOptions(ingestionUrl = if (uploadEnabled) "http://127.0.0.1:${server.localPort}" else null),
            ))
            block(activity, queue, completions)
        } finally {
            controller.pause().stop().destroy()
            server.close()
            serverThread.join(1_000)
            stopDelivery()
            queue.reports().forEach { queue.remove(it.reportId) }
            activity.noBackupFilesDir.resolve("crumb/javascript-crashes").deleteRecursively()
        }
    }
}
