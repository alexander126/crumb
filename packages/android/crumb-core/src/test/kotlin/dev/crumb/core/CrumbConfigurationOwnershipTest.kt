package dev.crumb.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test

class CrumbConfigurationOwnershipTest {
    @Before
    fun setUp() = Crumb.resetForTesting()

    @After
    fun tearDown() = Crumb.resetForTesting()

    /**
     * The defect this fixes: start stored the caller's instance, so the caller
     * kept a live handle on the SDK's invocation, evidence and privacy
     * configuration after it had been validated and started.
     */
    @Test
    fun clearingTheCallersInvocationSetDoesNotDisableInvocation() {
        val invocation = mutableSetOf(CrumbInvocation.SHAKE, CrumbInvocation.PROGRAMMATIC)
        Crumb.start(configuration(invocation = invocation))

        invocation.clear()

        assertEquals(
            setOf(CrumbInvocation.SHAKE, CrumbInvocation.PROGRAMMATIC),
            Crumb.reportSettings().invocation,
        )
    }

    @Test
    fun addingToTheCallersInvocationSetDoesNotEnableAnUnvalidatedPath() {
        val invocation = mutableSetOf(CrumbInvocation.PROGRAMMATIC)
        Crumb.start(configuration(invocation = invocation))

        invocation.add(CrumbInvocation.SHAKE)

        assertEquals(setOf(CrumbInvocation.PROGRAMMATIC), Crumb.reportSettings().invocation)
    }

    @Test
    fun mutatingTheCallersEvidenceSetDoesNotChangeCollectedEvidence() {
        val evidence = mutableSetOf(CrumbEvidenceCategory.LOGS, CrumbEvidenceCategory.PERFORMANCE)
        Crumb.start(configuration(evidence = evidence))

        evidence.clear()

        assertEquals(
            setOf(CrumbEvidenceCategory.LOGS, CrumbEvidenceCategory.PERFORMANCE),
            Crumb.reportSettings().evidence,
        )
    }

    @Test
    fun mutatingTheCallersVisibleFieldsDoesNotChangeTheReporter() {
        val visibleFields = mutableSetOf(CrumbReporterField.DESCRIPTION)
        Crumb.start(configuration(visibleFields = visibleFields))

        visibleFields.add(CrumbReporterField.CATEGORY)

        assertEquals(
            setOf(CrumbReporterField.DESCRIPTION),
            Crumb.reportSettings().reporter.visibleFields,
        )
    }

    @Test
    fun mutatingTheCallersCustomContextDoesNotChangeThePrivacyBoundary() {
        val values = mutableMapOf("build_channel" to "beta")
        val allowedKeys = mutableSetOf("build_channel")
        Crumb.start(configuration(customContextValues = values, allowedKeys = allowedKeys))

        values["session_token"] = "synthetic-value"
        allowedKeys.add("session_token")

        assertEquals(mapOf("build_channel" to "beta"), Crumb.reportSettings().customContext)
    }

    @Test
    fun startingAgainWithAnEqualConfigurationStillSucceeds() {
        Crumb.start(configuration(invocation = mutableSetOf(CrumbInvocation.PROGRAMMATIC)))

        Crumb.start(configuration(invocation = mutableSetOf(CrumbInvocation.PROGRAMMATIC)))

        assertEquals(setOf(CrumbInvocation.PROGRAMMATIC), Crumb.reportSettings().invocation)
    }

    @Test
    fun startingAgainWithADifferentConfigurationStillThrows() {
        Crumb.start(configuration(invocation = mutableSetOf(CrumbInvocation.PROGRAMMATIC)))

        assertThrows(CrumbStartException.AlreadyStarted::class.java) {
            Crumb.start(configuration(invocation = mutableSetOf(CrumbInvocation.SHAKE)))
        }
    }

    private fun configuration(
        invocation: Set<CrumbInvocation> = setOf(CrumbInvocation.PROGRAMMATIC),
        evidence: Set<CrumbEvidenceCategory> = CrumbEvidenceCategory.entries.toSet(),
        visibleFields: Set<CrumbReporterField> = setOf(
            CrumbReporterField.CATEGORY,
            CrumbReporterField.DESCRIPTION,
        ),
        customContextValues: Map<String, String> = emptyMap(),
        allowedKeys: Set<String> = emptySet(),
    ) = CrumbConfiguration(
        projectKey = "synthetic_ownership_write_key",
        environment = "test",
        release = CrumbRelease(appVersion = "1.0.0", nativeBuild = "1"),
        invocation = invocation,
        evidence = evidence,
        reporter = CrumbReporterOptions(visibleFields = visibleFields),
        customContext = CrumbCustomContextOptions(
            values = customContextValues,
            allowedKeys = allowedKeys,
        ),
    )
}
