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

/**
 * One install per test class: `CrumbReporter` and `CrumbUploadCoordinator` are
 * process singletons, and Robolectric hands each test method a fresh
 * Application, so a second install in the same class would take the
 * "different application" path instead of the one under test.
 */
@RunWith(RobolectricTestRunner::class)
class CrumbInstallForegroundTest {
    /**
     * The defect this fixes: registerActivityLifecycleCallbacks does not replay,
     * so installing after the host Activity had already resumed left queued
     * reports waiting for the next transition - while install returned true.
     */
    @Before
    fun setUp() = CrumbReporter.resetForTesting()

    @After
    fun tearDown() = CrumbReporter.resetForTesting()

    @Test
    fun installingWithoutAnActivityInAForegroundAppStartsDelivery() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        startCrumb()

        val installed = CrumbReporter.install(activity.application)

        assertTrue(installed)
        assertTrue(
            "delivery must be active after installing in a foreground app",
            CrumbUploadCoordinator.isDeliveryActive,
        )
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
