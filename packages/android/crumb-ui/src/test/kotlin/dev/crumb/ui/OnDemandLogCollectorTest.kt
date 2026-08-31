package dev.crumb.ui

import dev.crumb.core.CrumbLogCaptureStatus
import dev.crumb.core.CrumbLogEntry
import dev.crumb.core.CrumbLogLevel
import dev.crumb.core.CrumbLogOptions
import dev.crumb.core.CrumbLogProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OnDemandLogCollectorTest {
    @Test
    fun sanitizesSensitiveValues() {
        val raw = "email=user@example.com Authorization: Bearer abc.def token=hunter2 " +
            "https://admin:password@example.com?a=1&b=2\nforged-line"
        val sanitized = LogSanitizer.sanitize(raw)

        assertFalse(sanitized.contains("user@example.com"))
        assertFalse(sanitized.contains("abc.def"))
        assertFalse(sanitized.contains("hunter2"))
        assertFalse(sanitized.contains("a=1"))
        assertFalse(sanitized.contains("admin:password"))
        assertFalse(sanitized.contains('\n'))
        assertTrue(sanitized.contains("[REDACTED_EMAIL]"))
    }

    @Test
    fun keepsNewestEntriesWithinConfiguredBound() {
        val now = System.currentTimeMillis()
        val provider = CrumbLogProvider {
            listOf(
                entry(now - 3_000, "oldest"),
                entry(now - 2_000, "middle"),
                entry(now - 1_000, "newest"),
            )
        }

        val result = OnDemandLogCollector.capture(
            CrumbLogOptions(maximumEntries = 2, provider = provider),
        )

        assertEquals(CrumbLogCaptureStatus.CAPTURED, result.status)
        assertEquals(listOf("middle", "newest"), result.entries.map(CrumbLogEntry::message))
        assertTrue(result.truncated)
        assertEquals(1, result.droppedEntryCount)
    }

    private fun entry(timestamp: Long, message: String) = CrumbLogEntry(
        timestampMillis = timestamp,
        level = CrumbLogLevel.INFO,
        category = "test",
        message = message,
    )
}
