package dev.crumb.ui

import android.app.Activity
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbRelease
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

/** Preserved behavior: passing an already-resumed Activity still works. */
@RunWith(RobolectricTestRunner::class)
class CrumbInstallWithActivityTest {
    @Before
    fun setUp() = CrumbReporter.resetForTesting()

    @After
    fun tearDown() = CrumbReporter.resetForTesting()

    @Test
    fun installingWithAnAlreadyResumedActivityStartsDelivery() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        startCrumb()

        val installed = CrumbReporter.install(activity.application, activity)

        assertTrue(installed)
        assertTrue(CrumbUploadCoordinator.isDeliveryActive)
    }

    /**
     * Robolectric reuses one sandbox across test classes and `Crumb`'s reset is
     * internal to crumb-core, so another class may already have started it with
     * a different configuration. This test asserts delivery state, which does
     * not depend on which configuration won.
     */
    private fun startCrumb() {
        runCatching {
            Crumb.start(
                CrumbConfiguration(
                    projectKey = "synthetic_install_write_key",
                    environment = "test",
                    release = CrumbRelease(appVersion = "1.0.0", nativeBuild = "1"),
                    invocation = setOf(CrumbInvocation.PROGRAMMATIC),
                    capture = CrumbCaptureOptions(screenshot = false),
                    evidence = setOf(CrumbEvidenceCategory.LOGS),
                ),
            )
        }
    }
}
