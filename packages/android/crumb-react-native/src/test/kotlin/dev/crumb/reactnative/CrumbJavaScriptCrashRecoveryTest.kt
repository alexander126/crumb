package dev.crumb.reactnative

import dev.crumb.core.Crumb
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbDiagnosticsOptions
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbJavaScriptBreadcrumb
import dev.crumb.core.CrumbJavaScriptCrash
import dev.crumb.core.CrumbJavaScriptCrashRelease
import dev.crumb.core.CrumbJavaScriptFailureContext
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbRenderingEvidence
import dev.crumb.core.CrumbReportRuntime
import dev.crumb.core.CrumbStackTraceCaptureStatus
import dev.crumb.core.CrumbStackTraceDiagnostic
import dev.crumb.core.CrumbThreadStackDiagnostic
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Test

/**
 * Recovery maps a stored handoff onto a report build input. It moved here with
 * the handoff machinery; the envelope contract for `javascript_crash` stays
 * covered in crumb-core by CrumbTest.
 */
class CrumbJavaScriptCrashRecoveryTest {
    @Before
    fun setUp() {
        Crumb.resetForTesting()
    }

    @Test
    fun recoveryReappliesDisabledEvidenceToPreviouslyCapturedContext() {
        Crumb.start(configuration(evidence = emptySet()))
        val settings = Crumb.reportSettings()
        CrumbRenderingEvidence.provider = { "should be ignored while disabled" }
        assertEquals(null, CrumbRenderingEvidence.snapshot(settings))
        CrumbRenderingEvidence.provider = null
        val context = CrumbJavaScriptFailureContext(1_700_000_000_000, "SyntheticApp", 777,
            12.0, 12_000_000, 12, "nominal", "reachable", "wifi", false, false,
            CrumbStackTraceDiagnostic(CrumbStackTraceCaptureStatus.CAPTURED, "managed_threads",
                listOf(CrumbThreadStackDiagnostic(1, "main", "waiting", listOf("Synthetic.run(File.kt:1)"))), false, null))
        val time = java.time.Instant.ofEpochMilli(context.capturedAtMillis)
        val crash = CrumbJavaScriptCrash("jsc_0123456789ABCDEF", "0123456789abcdef",
            "javascript", "exception", "Error", "Synthetic failure", null, time,
            CrumbJavaScriptCrashRelease("1", "1", null),
            listOf(CrumbJavaScriptBreadcrumb(time, "crumb", "test", "previously allowed")), emptyMap(), true, false)
        crash.failureContext = context
        val input = CrumbJavaScriptCrashRecovery.recoveryInput(crash, settings,
            CrumbReportRuntime("test", "Synthetic device", "en-US", "UTC"))
        assertEquals(777, input.diagnostics.processId)
        assertEquals(context.capturedAtMillis, input.diagnostics.capturedAtMillis)
        val root = JSONObject(Crumb.buildReport(input).json)
        val diagnostics = root.getJSONObject("diagnostics")
        assertEquals(0, root.getJSONObject("javascript_crash").getJSONArray("breadcrumbs").length())
        assertFalse(diagnostics.has("cpu_usage_percent"))
        assertFalse(diagnostics.has("memory"))
        assertEquals("unknown", diagnostics.getJSONObject("network").getString("status"))
        assertEquals(0, diagnostics.getJSONObject("stack_traces").getJSONArray("threads").length())
    }

    private fun configuration(
        evidence: Set<CrumbEvidenceCategory> = CrumbEvidenceCategory.entries.toSet(),
    ) = CrumbConfiguration(
        projectKey = "synthetic_recovery_write_key",
        environment = "test",
        release = CrumbRelease(appVersion = "1.0.0", nativeBuild = "1"),
        invocation = setOf(CrumbInvocation.PROGRAMMATIC),
        capture = CrumbCaptureOptions(screenshot = false),
        diagnostics = CrumbDiagnosticsOptions(javascriptCrashCaptureEnabled = true),
        evidence = evidence,
    )
}
