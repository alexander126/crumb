package dev.crumb.core

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrumbJavaScriptCrashTest {
    @Test
    fun sanitizesAndDeduplicatesJavaScriptAndNativeWrapperOccurrences() {
        val root = temporaryRoot()
        try {
            val store = CrumbJavaScriptCrashStore(root)
            val settings = settings()
            val first = CrumbJavaScriptCrash(
                kind = CrumbJavaScriptCrashKind.FATAL_EXCEPTION,
                errorType = "TypeError",
                message = "Authorization: Bearer secret email=user@example.invalid",
                rawStack = "TypeError: failed\n    at checkout (Checkout.kt:42:7)",
                fingerprint = "js_shared",
                occurredAtMillis = 1_700_000_000_000,
                breadcrumbs = listOf(
                    CrumbJavaScriptBreadcrumb(1_699_999_999_000, "checkout", "started"),
                ),
            )
            val wrapper = CrumbJavaScriptCrash(
                kind = CrumbJavaScriptCrashKind.FATAL_EXCEPTION,
                source = CrumbJavaScriptCrashSource.NATIVE_TERMINATION_WRAPPER,
                errorType = "NativeTermination",
                message = "native wrapper",
                fingerprint = "js_shared",
                occurredAtMillis = 1_700_000_001_000,
                nativeTerminationWrapper = true,
            )

            assertTrue(store.record(first, settings))
            assertTrue(store.record(wrapper, settings))

            val record = store.records().single()
            assertEquals(CrumbJavaScriptCrashSource.JAVASCRIPT, record.crash.source)
            assertTrue(record.crash.nativeTerminationWrapper)
            assertTrue(record.crash.message.contains("[REDACTED]"))
            assertFalse(record.crash.message.contains("secret"))
            assertFalse(record.crash.message.contains("user@example.invalid"))
            assertTrue(record.crash.rawStack?.contains('\n') == true)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun recoversIntoTheDurableQueueAndDoesNotDuplicateAfterRelaunch() {
        val storeRoot = temporaryRoot()
        val queueRoot = temporaryRoot()
        try {
            val store = CrumbJavaScriptCrashStore(storeRoot)
            val queue = CrumbReportQueue(queueRoot)
            val settings = settings()
            assertTrue(
                store.record(
                    CrumbJavaScriptCrash(
                        kind = CrumbJavaScriptCrashKind.UNHANDLED_REJECTION,
                        errorType = "Error",
                        message = "Promise rejected",
                        rawStack = "Error: Promise rejected\n    at loadData (data.kt:10:2)",
                        fingerprint = "js_recovery",
                        occurredAtMillis = 1_700_000_000_000,
                    ),
                    settings,
                ),
            )
            val runtime = CrumbJavaScriptCrashRuntime(
                osVersion = "35",
                deviceFamily = "Pixel",
                locale = "en-US",
                timezone = "UTC",
                processName = "Example",
                processId = 42,
            )

            assertEquals(1, CrumbJavaScriptCrashRecovery.recoverPending(store, queue, settings, runtime))
            assertTrue(store.records().isEmpty())
            val report = queue.reports().single()
            val envelope = JSONObject(String(queue.load(report.reportId).envelope, Charsets.UTF_8))
            assertEquals("javascript_crash", envelope.getString("trigger"))
            assertTrue(envelope.has("javascript_crash"))
            assertEquals(
                "crash_recovery",
                envelope.getJSONObject("privacy").getString("diagnostics_capture"),
            )
            assertEquals(0, CrumbJavaScriptCrashRecovery.recoverPending(store, queue, settings, runtime))
            assertEquals(1, queue.reports().size)
        } finally {
            storeRoot.deleteRecursively()
            queueRoot.deleteRecursively()
        }
    }

    @Test
    fun keepsThePendingHandoffWhenTheReportQueueIsFull() {
        val storeRoot = temporaryRoot()
        val queueRoot = temporaryRoot()
        try {
            val store = CrumbJavaScriptCrashStore(storeRoot)
            val queue = CrumbReportQueue(
                queueRoot,
                CrumbQueueLimits(
                    maximumReports = 1,
                    maximumTotalBytes = 4_096,
                    maximumReportBytes = 4_096,
                    maximumEnvelopeBytes = 2_048,
                    maximumArtifactBytes = 1_024,
                    maximumArtifactsPerReport = 0,
                ),
            )
            val existingId = "rpt_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            queue.enqueue(
                CrumbSerializedReportEnvelope(
                    reportId = existingId,
                    submittedAtMillis = 1_700_000_000_000,
                    json = "{\"artifacts\":[],\"report_id\":\"$existingId\"}",
                ),
                emptyList(),
            )
            val settings = settings()
            assertTrue(
                store.record(
                    CrumbJavaScriptCrash(
                        kind = CrumbJavaScriptCrashKind.FATAL_EXCEPTION,
                        errorType = "Error",
                        message = "queue full",
                        fingerprint = "js_full",
                    ),
                    settings,
                ),
            )
            assertEquals(
                0,
                CrumbJavaScriptCrashRecovery.recoverPending(
                    store,
                    queue,
                    settings,
                    runtime(),
                ),
            )
            assertEquals(1, store.records().size)
            assertEquals(1, queue.reports().size)
        } finally {
            storeRoot.deleteRecursively()
            queueRoot.deleteRecursively()
        }
    }

    @Test
    fun ignoresCorruptPendingStorageAndEnforcesRecordLimit() {
        val root = temporaryRoot()
        try {
            File(root, "pending-javascript-crashes.json").writeText("not-json")
            val store = CrumbJavaScriptCrashStore(root)
            val settings = settings()
            assertTrue(store.records().isEmpty())
            repeat(8) { index ->
                assertTrue(
                    store.record(
                        CrumbJavaScriptCrash(
                            kind = CrumbJavaScriptCrashKind.UNHANDLED_REJECTION,
                            errorType = "Error",
                            message = "failure $index",
                            fingerprint = "js_limit_$index",
                        ),
                        settings,
                    ),
                )
            }
            assertFalse(
                store.record(
                    CrumbJavaScriptCrash(
                        kind = CrumbJavaScriptCrashKind.UNHANDLED_REJECTION,
                        errorType = "Error",
                        message = "failure over limit",
                        fingerprint = "js_limit_over",
                    ),
                    settings,
                ),
            )
            assertEquals(8, store.records().size)
        } finally {
            root.deleteRecursively()
        }
    }

    private fun settings() = CrumbReportSettings(
        environment = "test",
        release = CrumbRelease("1.0.0", "1"),
        invocation = setOf(CrumbInvocation.PROGRAMMATIC),
        capture = CrumbCaptureOptions(),
        diagnostics = CrumbDiagnosticsOptions(),
        privacy = CrumbPrivacyOptions(),
        reporter = CrumbReporterOptions(),
        evidence = setOf(CrumbEvidenceCategory.CUSTOM_CONTEXT),
        application = CrumbApplicationMetadata("Example"),
        customContext = mapOf("account_tier" to "trial"),
        policyStatus = CrumbPolicyStatus.NOT_CONFIGURED,
        workspacePolicyVersion = null,
    )

    private fun runtime() = CrumbJavaScriptCrashRuntime(
        osVersion = "35",
        deviceFamily = "Pixel",
        locale = "en-US",
        timezone = "UTC",
        processName = "Example",
        processId = 42,
    )

    private fun temporaryRoot(): File = Files.createTempDirectory("crumb-js-crash-tests-").toFile()
}
