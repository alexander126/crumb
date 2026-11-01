package dev.crumb.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LogSanitizerTest {
    @Test
    fun redactsQuotedNestedCredentialsWithoutRemovingSafeMetadata() {
        val raw = """metadata={"credentials":{"password":"synthetic-password","api_key":"synthetic-api-key"},"screen":"checkout"}"""

        val sanitized = LogSanitizer.sanitize(raw)

        assertFalse(sanitized.contains("synthetic-password"))
        assertFalse(sanitized.contains("synthetic-api-key"))
        assertTrue(sanitized.contains("\"screen\":\"checkout\""))
    }

    @Test
    fun redactsCommonTokenAndSecretKeySpellings() {
        val keys = listOf(
            "access_token", "accessToken", "access-token",
            "refresh_token", "refreshToken", "refresh-token",
            "id_token", "idToken", "id-token", "authToken", "sessionToken",
            "client_secret", "clientSecret", "client-secret", "apiKey", "X-API-Key",
        )

        keys.forEach { key ->
            val sanitized = LogSanitizer.sanitize("""{"$key":"synthetic-credential","event":"checkout"}""")
            assertFalse("credential retained for $key", sanitized.contains("synthetic-credential"))
            assertTrue("safe sibling removed for $key", sanitized.contains("\"event\":\"checkout\""))
        }
    }

    @Test
    fun redactsCredentialsAcrossSeparatorLineBreaks() {
        val plain = LogSanitizer.sanitize("password:\nsynthetic-value status=503")
        assertFalse(plain.contains("synthetic-value"))
        assertTrue(plain.contains("status=503"))
        val json = LogSanitizer.sanitize("{\"password\"\n:\n\"synthetic-value\",\"safe\":true}")
        assertFalse(json.contains("synthetic-value"))
        assertTrue(json.contains("\"safe\":true"))
    }

    @Test
    fun redactsEscapedAndTruncatedQuotedValues() {
        val samples = listOf(
            """{"password":"synthetic-head\"synthetic-tail","screen":"checkout"}""",
            """{'password':'synthetic-head\'synthetic-tail','screen':'checkout'}""",
            """{"password":"synthetic-head\\synthetic-tail","screen":"checkout"}""",
            """{"password":"synthetic-head\"synthetic-tail""",
            """{"password":"synthetic-head\""",
        )

        samples.forEach { sample ->
            val sanitized = LogSanitizer.sanitize(sample)
            assertFalse("credential prefix retained", sanitized.contains("synthetic-head"))
            assertFalse("credential suffix retained", sanitized.contains("synthetic-tail"))
        }
    }

    @Test
    fun redactsSensitiveContainersWithoutLeavingCredentialSuffixes() {
        val samples = listOf(
            """{"secret":{"nested":"synthetic-first","other":"synthetic-second"},"screen":"checkout"}""",
            """{"cookie":["a=synthetic-first","b=synthetic-second"],"screen":"checkout"}""",
            """{"Set-Cookie":["a=synthetic-first; Path=/","b=synthetic-second"],"screen":"checkout"}""",
            "{\"cookie\":[\n\"a=synthetic-first\",\n\"b=synthetic-second\"\n]}",
        )

        samples.forEach { sample ->
            val sanitized = LogSanitizer.sanitize(sample)
            assertFalse("sensitive container retained credential bytes", sanitized.contains("synthetic-"))
            assertEquals(sanitized, LogSanitizer.sanitize(sanitized))
        }
    }

    @Test
    fun redactsLongEscapedValuesWithoutRecursiveRegexBacktracking() {
        val escapedValue = "synthetic-\\\"".repeat(6_000)
        val raw = """{"password":"$escapedValue","screen":"checkout"}"""

        assertEquals(
            """{"password":"[REDACTED]","screen":"checkout"}""",
            LogSanitizer.sanitize(raw),
        )
    }

    @Test
    fun redactsCredentialsThatOnlyBeginWithAnExistingMarker() {
        val samples = listOf(
            "token=[REDACTED]synthetic-tail",
            "password=[REDACTED]{nested:synthetic-tail}",
        )

        samples.forEach { sample ->
            assertFalse(LogSanitizer.sanitize(sample).contains("synthetic-tail"))
        }
    }

    @Test
    fun preservesOnlyCompleteMarkersAtScalarAndJsonBoundaries() {
        val samples = listOf(
            "token=[REDACTED]",
            "token=[REDACTED] screen=checkout",
            "cookie=[REDACTED]; screen=checkout",
            """{"token":[REDACTED],"screen":"checkout"}""",
            """{"password":[REDACTED]}""",
            "cookie=[REDACTED]]",
        )

        samples.forEach { sample ->
            assertEquals(sample, LogSanitizer.sanitize(sample))
        }
    }

    @Test
    fun redactsWholeAuthorizationAndProxyAuthorizationValues() {
        val raw = "Authorization: Basic synthetic-basic\r\n" +
            "Authorization: Digest username=synthetic-user, response=synthetic-response\r\n" +
            "Proxy-Authorization: Custom synthetic-proxy value\r\n" +
            "screen=checkout"

        val sanitized = LogSanitizer.sanitize(raw)

        assertFalse(sanitized.contains("synthetic-"))
        assertTrue(sanitized.contains("screen=checkout"))
        assertEquals(sanitized, LogSanitizer.sanitize(sanitized))
        val json = LogSanitizer.sanitize("""{"Authorization":"Basic synthetic-json","screen":"checkout"}""")
        assertFalse(json.contains("synthetic-json"))
        assertTrue(json.contains("\"screen\":\"checkout\""))
    }

    @Test
    fun redactsWholeCookieHeadersAndFoldedContinuations() {
        val raw = "Cookie: session=synthetic-session; refresh=synthetic-refresh\r\n" +
            "Set-Cookie: session=synthetic-set; Secure; HttpOnly\r\n" +
            "Cookie: session=synthetic-folded\r\n\trefresh=synthetic-continuation\r\n" +
            "screen=checkout"

        val sanitized = LogSanitizer.sanitize(raw)

        assertFalse(sanitized.contains("synthetic-"))
        assertTrue(sanitized.contains("screen=checkout"))
        assertEquals(sanitized, LogSanitizer.sanitize(sanitized))
        val json = LogSanitizer.sanitize("""{"Cookie":"a=synthetic-a; b=synthetic-b","screen":"checkout"}""")
        assertFalse(json.contains("synthetic-"))
        assertTrue(json.contains("\"screen\":\"checkout\""))
    }

    @Test
    fun preservesSafeKeysExistingRedactionsAndIdempotence() {
        val safe = """{"tokenCount":3,"secretary":"public","screen":"checkout"}"""
        assertEquals(safe, LogSanitizer.sanitize(safe))
        val raw = "email=person@example.test https://synthetic-user:synthetic-pass@example.test?a=synthetic-query " +
            "card=4111111111111111\npassword=synthetic-password"

        val sanitized = LogSanitizer.sanitize(raw)

        assertFalse(sanitized.contains("synthetic-"))
        assertFalse(sanitized.contains("person@example.test"))
        assertFalse(sanitized.contains("4111111111111111"))
        assertFalse(sanitized.contains('\n'))
        assertEquals(sanitized, LogSanitizer.sanitize(sanitized))
    }
}
