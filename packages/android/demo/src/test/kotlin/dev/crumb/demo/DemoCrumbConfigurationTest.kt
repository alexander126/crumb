package dev.crumb.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DemoCrumbConfigurationTest {
    @Test
    fun blankLocalSettingsKeepNetworkDeliveryDisabled() {
        val result = DemoCrumbConfiguration.make(
            projectKey = "",
            ingestionUrl = "",
            environment = "",
            appVersion = "0.1.0",
            nativeBuild = "1",
        )

        assertEquals("Local-only mode", result.modeDescription)
        assertEquals("poc_write_key", result.crumb.projectKey)
        assertEquals("local", result.crumb.environment)
        assertNull(result.crumb.upload.ingestionUrl)
        assertNull(result.crumb.diagnostics.healthCheckUrl)
    }

    @Test
    fun completeDogfoodSettingsEnableStagingDelivery() {
        val result = DemoCrumbConfiguration.make(
            projectKey = "crumb_sdk_test_key",
            ingestionUrl = "https://api-staging.example.test/",
            environment = "staging",
            appVersion = "0.1.0",
            nativeBuild = "1",
        )

        assertEquals("Staging upload enabled", result.modeDescription)
        assertEquals("crumb_sdk_test_key", result.crumb.projectKey)
        assertEquals("staging", result.crumb.environment)
        assertEquals("https://api-staging.example.test", result.crumb.upload.ingestionUrl)
        assertEquals(
            "https://api-staging.example.test/health",
            result.crumb.diagnostics.healthCheckUrl,
        )
    }

    @Test
    fun missingKeyOrInvalidUrlFallsBackToLocalOnly() {
        val missingKey = DemoCrumbConfiguration.make(
            projectKey = "",
            ingestionUrl = "https://api-staging.example.test",
        )
        val invalidUrl = DemoCrumbConfiguration.make(
            projectKey = "crumb_sdk_test_key",
            ingestionUrl = "file:///tmp/crumb",
        )

        assertEquals("Local-only mode", missingKey.modeDescription)
        assertNull(missingKey.crumb.upload.ingestionUrl)
        assertEquals("Local-only mode", invalidUrl.modeDescription)
        assertNull(invalidUrl.crumb.upload.ingestionUrl)
    }
}
