package dev.crumb.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.SocketTimeoutException

class CrumbInfrastructureHealthProbeTest {
    @Test
    fun recordsAHealthyCrumbHeadResponse() {
        val diagnostic = CrumbInfrastructureHealthProbe.capture(
            value = "https://ingestion.crumb.dev/health",
            timeoutMillis = 1_250,
        ) { url, timeout ->
            assertEquals("https://ingestion.crumb.dev/health", url.toString())
            assertEquals(1_250, timeout)
            CrumbHealthHeadResult(statusCode = 204, latencyMilliseconds = 18, failure = null)
        }

        assertEquals("ingestion.crumb.dev", diagnostic.host)
        assertTrue(diagnostic.succeeded)
        assertEquals(204, diagnostic.statusCode)
        assertEquals(18, diagnostic.latencyMilliseconds)
        assertNull(diagnostic.failure)
    }

    @Test
    fun turnsAnUnavailableCrumbApiIntoEvidenceInsteadOfAnError() {
        val diagnostic = CrumbInfrastructureHealthProbe.capture(
            value = "https://ingestion.crumb.dev/health",
            timeoutMillis = 1_250,
        ) { _, _ ->
            throw SocketTimeoutException("test timeout")
        }

        assertFalse(diagnostic.succeeded)
        assertNull(diagnostic.statusCode)
        assertEquals(0, diagnostic.latencyMilliseconds)
        assertEquals("timeout", diagnostic.failure)
    }

    @Test
    fun doesNotTreatAnUnhealthyHttpResponseAsSuccess() {
        val diagnostic = CrumbInfrastructureHealthProbe.capture(
            value = "https://ingestion.crumb.dev/health",
            timeoutMillis = 1_000,
        ) { _, _ ->
            CrumbHealthHeadResult(statusCode = 503, latencyMilliseconds = 9, failure = null)
        }

        assertFalse(diagnostic.succeeded)
        assertEquals(503, diagnostic.statusCode)
    }
}
