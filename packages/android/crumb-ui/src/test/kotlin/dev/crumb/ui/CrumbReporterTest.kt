package dev.crumb.ui

import android.app.Activity
import android.app.Application
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbConfigurationContract
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbWorkspacePolicyOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class CrumbReporterTest {
    @Test
    fun directShowUsesCachedWorkspacePolicyBeforeCreatingSession() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val application = activity.application
        val policyUrl = "http://127.0.0.1:1/sdk/v1/policy"
        Crumb.start(
            CrumbConfiguration(
                projectKey = "reporter-test-project",
                environment = "test",
                release = CrumbRelease(appVersion = "1.0.0", nativeBuild = "1"),
                invocation = setOf(CrumbInvocation.PROGRAMMATIC),
                capture = CrumbCaptureOptions(screenshot = false),
                evidence = setOf(CrumbEvidenceCategory.LOGS),
                workspacePolicy = CrumbWorkspacePolicyOptions(
                    url = policyUrl,
                    timeoutMillis = 250,
                ),
            ),
        )

        application.getSharedPreferences("crumb.workspace-policy", Application.MODE_PRIVATE)
            .edit()
            .putString(
                Crumb.workspacePolicyCacheKey(),
                """
                {"schema_version":"${CrumbConfigurationContract.VERSION}","version":7,"expires_at":"2099-01-01T00:00:00Z","disabled_evidence":[],"hidden_reporter_fields":["category"],"allowed_context_keys":[]}
                """.trimIndent(),
            )
            .commit()

        assertTrue(CrumbReporter.show(activity))
        val activeSessionField = CrumbReporter::class.java.getDeclaredField("activeSession")
        activeSessionField.isAccessible = true
        val session = activeSessionField.get(CrumbReporter)
        val settingsField = requireNotNull(session)::class.java.getDeclaredField("settings")
        settingsField.isAccessible = true
        val settings = settingsField.get(session) as dev.crumb.core.CrumbReportSettings
        assertEquals(setOf(CrumbEvidenceCategory.LOGS), settings.evidence)

        val dialogField = requireNotNull(session)::class.java.getDeclaredField("dialog")
        dialogField.isAccessible = true
        (dialogField.get(session) as android.app.Dialog).dismiss()
    }
}
