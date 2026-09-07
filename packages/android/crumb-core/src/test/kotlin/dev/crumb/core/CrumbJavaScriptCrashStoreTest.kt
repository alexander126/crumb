package dev.crumb.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CrumbJavaScriptCrashStoreTest {
    @Test
    fun deduplicatesNativeTerminationWrapperWithoutLosingJavaScriptCause() {
        val root = temporaryRoot()
        try {
            val store = CrumbJavaScriptCrashStore(root)

            assertTrue(store.record(recordJson(source = "javascript", kind = "exception")))
            assertTrue(
                store.record(
                    recordJson(
                        source = "native_termination_wrapper",
                        kind = "native_termination_wrapper",
                    ),
                ),
            )

            val record = store.records().single()
            assertEquals("javascript", record.source)
            assertEquals("exception", record.kind)
            assertEquals("TypeError", record.type)
            assertEquals("JS exploded", record.message)
            assertTrue(record.stack?.contains("bundle.js") == true)
            assertTrue(record.isFatal)
            assertTrue(record.nativeTerminationWrapperObserved)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun sanitizesCrashFieldsAndNeverStoresUnallowlistedContext() {
        val root = temporaryRoot()
        try {
            val store = CrumbJavaScriptCrashStore(root)
            assertTrue(
                store.record(
                    recordJson(
                        kind = "unhandled_rejection",
                        message = "Bearer secret-value user@example.invalid",
                    ),
                ),
            )

            val record = store.records().single()
            assertTrue(record.message.contains("[REDACTED]"))
            assertTrue(record.message.contains("[REDACTED_EMAIL]"))
            assertEquals(mapOf("account_tier" to "trial"), record.context)
            assertEquals(1, record.breadcrumbs.size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun rejectsNewRecordsAtTheBoundWithoutEvictingExistingOccurrences() {
        val root = temporaryRoot()
        try {
            val store = CrumbJavaScriptCrashStore(
                root,
                CrumbJavaScriptCrashStoreLimits(
                    maximumRecords = 1,
                    maximumTotalBytes = 65_536,
                    maximumRecordBytes = 65_536,
                    maximumBreadcrumbs = 8,
                    maximumBreadcrumbBytes = 4_096,
                ),
            )
            assertTrue(store.record(recordJson(recordId = "jsc_AAAAAAAAAAAAAAAA", fingerprint = "aaaaaaaaaaaaaaaa")))
            assertFalse(store.record(recordJson(recordId = "jsc_BBBBBBBBBBBBBBBB", fingerprint = "bbbbbbbbbbbbbbbb")))
            assertEquals(listOf("jsc_AAAAAAAAAAAAAAAA"), store.records().map { it.recordId })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun skipsCorruptFilesAndRecoversValidOccurrences() {
        val root = temporaryRoot()
        try {
            assertTrue(root.isDirectory)
            File(root, "jsc_corruptcorruptcorrupt.json").writeText("not-json")
            val store = CrumbJavaScriptCrashStore(root)
            assertTrue(store.record(recordJson()))

            assertEquals(1, store.records().size)
            assertFalse(File(root, "jsc_corruptcorruptcorrupt.json").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun persistsFailureContextAndKeepsTheOriginalProcessWhenDeduplicating() {
        val root = temporaryRoot()
        try {
            val context = failureContext()
            assertTrue(CrumbJavaScriptCrashStore(root).record(recordJson(), context))
            val reopened = CrumbJavaScriptCrashStore(root)
            assertTrue(reopened.record(recordJson(source = "native_termination_wrapper", kind = "native_termination_wrapper")))
            val crash = reopened.records().single()
            assertEquals(context, crash.failureContext)
            val diagnostics = requireNotNull(crash.failureContext).diagnostics()
            assertEquals(777, diagnostics.processId)
            assertEquals(context.capturedAtMillis, diagnostics.capturedAtMillis)
            assertEquals(12_000_000L, diagnostics.residentMemoryBytes)
            assertEquals("react_native_javascript_failure", diagnostics.location)
            assertEquals("wifi", diagnostics.network.transport)
        } finally { root.deleteRecursively() }
    }

    @Test
    fun optionalContextCannotDisplaceTheCrashAndMalformedContextDoesNotDeleteIt() {
        val root = temporaryRoot()
        try {
            val json = recordJson()
            val store = CrumbJavaScriptCrashStore(root, CrumbJavaScriptCrashStoreLimits(maximumRecordBytes = json.toByteArray().size))
            assertTrue(store.record(json, failureContext()))
            assertEquals(1, store.records().size)
            assertTrue(requireNotNull(root.listFiles()).single().length() <= json.toByteArray().size)
            val file = requireNotNull(root.listFiles()).single()
            val value = org.json.JSONObject(file.readText()).put("failure_context", org.json.JSONObject().put("process_id", "invalid"))
            file.writeText(value.toString())
            assertEquals(1, store.records().size)
            assertEquals(null, store.records().single().failureContext)
        } finally { root.deleteRecursively() }
    }

    @Test
    fun ignoresJavaScriptInjectedContextAndDropsDisabledBreadcrumbsBeforePersistence() {
        val root = temporaryRoot()
        try {
            val store = CrumbJavaScriptCrashStore(root)
            assertTrue(store.record(recordJson(), failureContext()))
            val saved = requireNotNull(root.listFiles()).single().readText()
            assertTrue(store.remove(store.records().single().recordId))
            assertTrue(store.record(saved, null, includeBreadcrumbs = false))
            assertEquals(null, store.records().single().failureContext)
            assertTrue(store.records().single().breadcrumbs.isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test
    fun totalStoreBudgetDropsOnlyTheIncomingOptionalSnapshot() {
        val root = temporaryRoot()
        try {
            assertTrue(CrumbJavaScriptCrashStore(root).record(recordJson(), failureContext()))
            val existingBytes = requireNotNull(root.listFiles()).single().length()
            val json = recordJson(recordId = "jsc_AAAAAAAAAAAAAAAA", fingerprint = "aaaaaaaaaaaaaaaa")
            val budget = existingBytes + json.toByteArray().size
            val store = CrumbJavaScriptCrashStore(root, CrumbJavaScriptCrashStoreLimits(
                maximumTotalBytes = budget, maximumRecordBytes = budget.toInt()))
            assertTrue(store.record(json, failureContext()))
            assertEquals(2, store.records().size)
            assertTrue(store.records().single { it.recordId == "jsc_0123456789ABCDEF" }.failureContext != null)
            assertEquals(null, store.records().single { it.recordId == "jsc_AAAAAAAAAAAAAAAA" }.failureContext)
        } finally { root.deleteRecursively() }
    }

    @Test
    fun cpuSampleUsesMillisecondsAndRejectsInvalidIntervals() {
        assertEquals(50.0, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(10, 20_000_000))
        assertEquals(0.0, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(0, 20_000_000))
        assertEquals(null, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(10, 0))
        assertEquals(null, CrumbJavaScriptFailureContext.calculateCpuUsagePercent(-1, 20_000_000))
    }

    private fun failureContext() = CrumbJavaScriptFailureContext(
        1_788_350_400_000, "SyntheticApp", 777, 0.0, 12_000_000, 12, "nominal", "reachable", "wifi", false, false,
    )

    private fun temporaryRoot(): File = Files.createTempDirectory("crumb-js-crash-tests-").toFile()

    private fun recordJson(
        recordId: String = "jsc_0123456789ABCDEF",
        fingerprint: String = "0123456789abcdef",
        source: String = "javascript",
        kind: String = "exception",
        message: String = "JS exploded",
    ): String = """
        {
          "schema_version": "1.0",
          "record_id": "$recordId",
          "fingerprint": "$fingerprint",
          "source": "$source",
          "kind": "$kind",
          "type": "TypeError",
          "message": "$message",
          "stack": "TypeError: JS exploded\\n    at screen (bundle.js:10:4)",
          "occurred_at": "2026-09-02T12:00:00Z",
          "release": {
            "app_version": "1.2.3",
            "native_build": "42",
            "bundle_version": "ota-17"
          },
          "breadcrumbs": [
            {
              "timestamp": "2026-09-02T11:59:59Z",
              "source": "react-native",
              "category": "javascript",
              "message": "checkout started"
            }
          ],
          "context": {
            "account_tier": "trial",
            "token": "should not persist"
          },
          "is_fatal": true,
          "native_termination_wrapper_observed": false
        }
    """.trimIndent()
}
