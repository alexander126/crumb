package dev.crumb.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrumbCredentialRedactionTest {
    @Test
    fun distinguishesCompleteMarkersFromCredentialPrefixesInAllCoreSinks() {
        val credentials = listOf(
            "token=[REDACTED]synthetic-tail",
            "password=[REDACTED]{nested:synthetic-tail}",
        )
        credentials.forEach { sample ->
            assertFalse(CrumbFailureText.sanitize(sample).contains("synthetic-tail"))
            val context = CrumbCustomContextSanitizer.sanitize(
                CrumbCustomContextOptions(values = mapOf("diagnostic" to sample), allowedKeys = setOf("diagnostic")),
            ).getValue("diagnostic")
            assertFalse(context.contains("synthetic-tail"))
        }
        val completeMarkers = listOf(
            "token=[REDACTED]",
            "cookie=[REDACTED]; screen=checkout",
            """{"token":[REDACTED],"screen":"checkout"}""",
            """{"password":[REDACTED]}""",
            "cookie=[REDACTED]]",
        )
        completeMarkers.forEach { sample ->
            assertEquals(sample, CrumbFailureText.sanitize(sample))
            val context = CrumbCustomContextSanitizer.sanitize(
                CrumbCustomContextOptions(values = mapOf("diagnostic" to sample), allowedKeys = setOf("diagnostic")),
            ).getValue("diagnostic")
            assertEquals(sample, context)
        }
    }

    @Test
    fun redactsCredentialsInFailureFieldsAndCustomContextValues() {
        val longEscapedValue = "synthetic-\\\"".repeat(6_000)
        val samples = listOf(
            """{"password":"synthetic-password","screen":"checkout"}""",
            """{"accessToken":"synthetic-token","client_secret":"synthetic-client","screen":"checkout"}""",
            """{"password":"synthetic-head\"synthetic-tail","screen":"checkout"}""",
            """{"password":"synthetic-head\"synthetic-tail""",
            "Authorization: Basic synthetic-basic\nscreen=checkout",
            "Authorization: Digest username=synthetic-user, response=synthetic-response\nscreen=checkout",
            "Proxy-Authorization: Basic synthetic-proxy\nscreen=checkout",
            "Cookie: a=synthetic-a; b=synthetic-b\nscreen=checkout",
            "Set-Cookie: a=synthetic-a; Secure\n\tb=synthetic-b\nscreen=checkout",
            "password:\nsynthetic-value screen=checkout",
            "{\"password\"\n:\n\"synthetic-value\",\"screen\":\"checkout\"}",
            """{"password":"$longEscapedValue","screen":"checkout"}""",
        )

        samples.forEach { sample ->
            val failure = CrumbFailureText.sanitize(sample, preserveNewlines = true)
            val context = CrumbCustomContextSanitizer.sanitize(
                CrumbCustomContextOptions(values = mapOf("diagnostic" to sample), allowedKeys = setOf("diagnostic")),
            ).getValue("diagnostic")
            listOf(failure, context).forEach { sanitized ->
                assertFalse("credential retained in diagnostic field", sanitized.contains("synthetic-"))
                if (sample.contains("checkout")) {
                    assertTrue("safe sibling removed", sanitized.contains("checkout"))
                }
            }
            assertEquals(failure, CrumbFailureText.sanitize(failure, preserveNewlines = true))
        }
    }
}
