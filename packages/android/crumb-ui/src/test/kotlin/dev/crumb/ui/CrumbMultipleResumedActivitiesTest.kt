package dev.crumb.ui

import android.app.Activity
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbInvocation
import dev.crumb.core.CrumbRelease
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class CrumbMultipleResumedActivitiesTest {
    @Before
    fun setUp() = CrumbReporter.resetForTesting()

    @After
    fun tearDown() = CrumbReporter.resetForTesting()

    /**
     * The defect this fixes: onActivityPaused paused delivery for any Activity.
     * Since Android 10 more than one Activity can be resumed, and a translucent
     * Activity can pause the one behind it while the app is still in front of
     * the user - so queued reports stopped draining for no visible reason.
     */
    @Test
    fun pausingOneOfTwoResumedActivitiesKeepsDeliveryActive() {
        val first = Robolectric.buildActivity(Activity::class.java).setup()
        startCrumb()
        CrumbReporter.install(first.get().application, first.get())
        val second = Robolectric.buildActivity(Activity::class.java).setup()
        assertTrue(CrumbUploadCoordinator.isDeliveryActive)

        first.pause()

        assertTrue(
            "delivery must stay active while another Activity is resumed",
            CrumbUploadCoordinator.isDeliveryActive,
        )
    }

    @Test
    fun pausingTheLastResumedActivityStopsDelivery() {
        val first = Robolectric.buildActivity(Activity::class.java).setup()
        startCrumb()
        CrumbReporter.install(first.get().application, first.get())
        val second = Robolectric.buildActivity(Activity::class.java).setup()

        first.pause()
        second.pause()

        assertFalse(CrumbUploadCoordinator.isDeliveryActive)
    }

    @Test
    fun ordinaryNavigationLeavesDeliveryActive() {
        val first = Robolectric.buildActivity(Activity::class.java).setup()
        startCrumb()
        CrumbReporter.install(first.get().application, first.get())

        // Pre-Q ordering: the outgoing Activity pauses, then the next resumes.
        first.pause()
        val second = Robolectric.buildActivity(Activity::class.java).setup()

        assertTrue(CrumbUploadCoordinator.isDeliveryActive)
    }

    @Test
    fun destroyingAPausedActivityDoesNotRestartDelivery() {
        val first = Robolectric.buildActivity(Activity::class.java).setup()
        startCrumb()
        CrumbReporter.install(first.get().application, first.get())

        first.pause()
        first.destroy()

        assertFalse(CrumbUploadCoordinator.isDeliveryActive)
    }

    /**
     * Robolectric reuses one sandbox across test classes and `Crumb`'s reset is
     * internal to crumb-core, so another class may already have started it with
     * a different configuration. These tests assert delivery state, which does
     * not depend on which configuration won.
     */
    private fun startCrumb() {
        runCatching { Crumb.start(configuration()) }
    }

    private fun configuration() = CrumbConfiguration(
        projectKey = "synthetic_multi_resume_write_key",
        environment = "test",
        release = CrumbRelease(appVersion = "1.0.0", nativeBuild = "1"),
        invocation = setOf(CrumbInvocation.PROGRAMMATIC),
        capture = CrumbCaptureOptions(screenshot = false),
        evidence = setOf(CrumbEvidenceCategory.LOGS),
    )
}
