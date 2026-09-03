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
