package dev.crumb.demo

import android.content.pm.ActivityInfo
import android.net.TrafficStats
import android.os.Debug
import android.os.Process
import android.os.ParcelFileDescriptor
import android.util.Log
import android.view.View
import android.view.inputmethod.InputMethodManager
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.closeSoftKeyboard
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.Espresso.pressBack
import androidx.test.espresso.UiController
import androidx.test.espresso.ViewAction
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.longClick
import androidx.test.espresso.action.ViewActions.replaceText
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.assertion.ViewAssertions.doesNotExist
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.isEnabled
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withTagValue
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import dev.crumb.ui.CrumbQualityEvent
import dev.crumb.ui.CrumbQualityEventKind
import dev.crumb.ui.CrumbQualityInstrumentation
import dev.crumb.ui.CrumbReporter
import org.hamcrest.CoreMatchers.allOf
import org.hamcrest.CoreMatchers.containsString
import org.hamcrest.CoreMatchers.equalTo
import org.hamcrest.Matcher
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.Collections
import kotlin.math.ceil

private fun directClick(): ViewAction = object : ViewAction {
    override fun getConstraints(): Matcher<View> = isDisplayed()

    override fun getDescription(): String = "invoke the displayed view click action"

    override fun perform(uiController: UiController, view: View) {
        check(view.performClick()) { "The displayed view did not accept its click action" }
        uiController.loopMainThreadUntilIdle()
    }
}

private fun isViewDisplayed(matcher: Matcher<View>): Boolean = runCatching {
    onView(matcher).check(matches(isDisplayed()))
}.isSuccess

@RunWith(AndroidJUnit4::class)
@LargeTest
class CrumbDemoUiTests {
    @get:Rule
    val activityRule = ActivityScenarioRule(MainActivity::class.java)

    @Before
    fun restorePortraitHost() {
        executeShell("settings put system accelerometer_rotation 0")
        executeShell("settings put system user_rotation 0")
        activityRule.scenario.onActivity {
            it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            it.currentFocus?.clearFocus()
            val inputMethod = it.getSystemService(InputMethodManager::class.java)
            inputMethod.hideSoftInputFromWindow(it.window.decorView.windowToken, 0)
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        waitFor(tagged("demo.report-problem"))
    }

    @After
    fun restoreAppearance() {
        executeShell("settings put system font_scale 1.0")
        executeShell("cmd uimode night no")
    }

    @Test
    fun interactiveDismissalAllowsAnotherReport() {
        onView(tagged("demo.report-problem")).perform(scrollTo(), click())
        waitFor(tagged("crumb.description"))

        closeSoftKeyboard()
        pressBack()
        onView(tagged("crumb.description")).check(doesNotExist())

        onView(tagged("demo.report-problem")).perform(scrollTo(), click())
        waitFor(tagged("crumb.description"))
        closeSoftKeyboard()
        pressBack()
    }

    @Test
    fun reportSurvivesRotationAndBackgrounding() {
        onView(tagged("demo.report-problem")).perform(scrollTo(), click())
        waitFor(tagged("crumb.description"))
        onView(tagged("crumb.description")).perform(replaceText("Keep this draft"))
        closeSoftKeyboard()

        activityRule.scenario.onActivity {
            it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        waitFor(allOf(tagged("crumb.description"), withText("Keep this draft")))

        executeShell("input keyevent KEYCODE_HOME")
        bringAppToForeground()
        waitFor(allOf(tagged("crumb.description"), withText("Keep this draft")))

        activityRule.scenario.onActivity {
            it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        waitFor(allOf(tagged("crumb.description"), withText("Keep this draft")))
        pressBack()
    }

    @Test
    fun createsLocalReportDraftWithMaskedEvidence() {
        onView(tagged("demo.simulate-activity")).perform(click())
        onView(tagged("demo.report-problem")).perform(scrollTo(), click())

        waitFor(withContentDescription("Masked screenshot preview"))
        waitFor(
            allOf(
                tagged("crumb.diagnostics-summary"),
                withContentDescription(containsString("Context ready")),
            ),
        )

        onView(tagged("crumb.description")).perform(
            replaceText("The payment button stopped responding"),
        )
        closeSoftKeyboard()
        waitFor(allOf(tagged("crumb.review-draft"), isEnabled()))
        onView(tagged("crumb.review-draft")).perform(scrollTo(), click())

        waitFor(withText("Review"))
        onView(withText(containsString("Nothing has been sent yet"))).check(matches(isDisplayed()))
        onView(withText("The payment button stopped responding")).check(matches(isDisplayed()))
        onView(withText(containsString("WHAT’S ATTACHED"))).check(matches(isDisplayed()))

        onView(tagged("crumb.submit-report")).perform(scrollTo(), click())
        waitFor(withText("Report saved"))
        onView(withText("Done")).perform(click())
        onView(tagged("demo.report-problem")).check(matches(isDisplayed()))
    }

    @Test
    fun screenshotCanBePreviewedAndRemoved() {
        onView(tagged("demo.report-problem")).perform(scrollTo(), click())
        waitFor(withContentDescription("Masked screenshot preview"))

        onView(withContentDescription("Masked screenshot preview")).perform(directClick())
        waitFor(withContentDescription("Close screenshot preview"))
        onView(withContentDescription("Close screenshot preview")).perform(click())

        onView(withText("Remove")).perform(scrollTo(), click())
        onView(withContentDescription("Masked screenshot preview")).check(doesNotExist())
        pressBack()
    }

    @Test
    fun shakeShowsCompactConfirmationBeforeReporter() {
        onView(tagged("demo.report-problem")).perform(scrollTo(), longClick())
        waitFor(tagged("crumb.shake-prompt-title"))
        onView(tagged("crumb.description")).check(doesNotExist())

        onView(tagged("crumb.shake-report")).perform(click())
        waitFor(tagged("crumb.description"))
        pressBack()
    }

    @Test
    fun qualityBudgetsProduceRepeatableMeasurements() {
        val events = Collections.synchronizedList(mutableListOf<CrumbQualityEvent>())
        CrumbQualityInstrumentation.observe(events::add)
        try {
            val uid = Process.myUid()
            val transmittedBefore = TrafficStats.getUidTxBytes(uid)
            val receivedBefore = TrafficStats.getUidRxBytes(uid)
            val writesBefore = processWriteBytes()
            val storageBefore = appStorageBytes()
            var starts = emptyList<Double>()
            activityRule.scenario.onActivity { starts = it.measureWarmStarts(20) }
            val startWriteBytes = writesBefore?.let { before ->
                processWriteBytes()?.let { after -> (after - before).coerceAtLeast(0) }
            }
            val startStorageBytes = (appStorageBytes() - storageBefore).coerceAtLeast(0)
            val startTransmittedBytes = trafficDelta(transmittedBefore, TrafficStats.getUidTxBytes(uid))
            val startReceivedBytes = trafficDelta(receivedBefore, TrafficStats.getUidRxBytes(uid))

            repeat(20) { run ->
                activityRule.scenario.onActivity { activity ->
                    check(CrumbReporter.show(activity)) { "Reporter did not open for run ${run + 1}" }
                }
                waitForQualityEvent(events, CrumbQualityEventKind.FORM_READY, run + 1)
                waitForQualityEvent(events, CrumbQualityEventKind.DIAGNOSTICS_READY, run + 1)
                waitForQualityEvent(events, CrumbQualityEventKind.SCREENSHOT_READY, run + 1)
                onView(withContentDescription("Close report")).perform(directClick())
                waitForQualityEvent(events, CrumbQualityEventKind.REPORTER_CLOSED, run + 1)
            }

            Runtime.getRuntime().gc()
            Thread.sleep(1_000)
            val memoryBeforeKiB = Debug.getPss()
            activityRule.scenario.onActivity { activity ->
                check(CrumbReporter.show(activity)) { "Reporter did not open for memory pass" }
            }
            waitForQualityEvent(events, CrumbQualityEventKind.DIAGNOSTICS_READY, 21)
            waitForQualityEvent(events, CrumbQualityEventKind.SCREENSHOT_READY, 21)
            onView(tagged("crumb.description")).perform(replaceText("Memory retention pass"))
            closeSoftKeyboard()
            waitFor(allOf(tagged("crumb.review-draft"), isEnabled()))
            onView(tagged("crumb.review-draft")).perform(scrollTo(), click())
            waitFor(withText("Review"))
            pressBack()
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (isViewDisplayed(tagged("crumb.description"))) {
                onView(withContentDescription("Close report")).perform(directClick())
                onView(withText("Discard report")).perform(directClick())
            }
            waitForQualityEvent(events, CrumbQualityEventKind.REPORTER_CLOSED, 21)
            Runtime.getRuntime().gc()
            Thread.sleep(5_000)
            val retainedMemoryBytes = ((Debug.getPss() - memoryBeforeKiB).coerceAtLeast(0)) * 1_024L

            val form = samples(events, CrumbQualityEventKind.FORM_READY).take(20)
            val diagnostics = samples(events, CrumbQualityEventKind.DIAGNOSTICS_READY).take(20)
            val screenshot = samples(events, CrumbQualityEventKind.SCREENSHOT_READY).take(20)
            val result = "start_p50=${percentile(starts, 0.50)} " +
                "start_p95=${percentile(starts, 0.95)} " +
                "form_p50=${percentile(form, 0.50)} form_p95=${percentile(form, 0.95)} " +
                "diagnostics_p50=${percentile(diagnostics, 0.50)} " +
                "diagnostics_p95=${percentile(diagnostics, 0.95)} " +
                "screenshot_p50=${percentile(screenshot, 0.50)} " +
                "screenshot_p95=${percentile(screenshot, 0.95)} " +
                "retained_bytes=$retainedMemoryBytes " +
                "start_write_bytes=${startWriteBytes ?: "unavailable"} " +
                "start_storage_bytes=$startStorageBytes " +
                "start_tx_bytes=$startTransmittedBytes start_rx_bytes=$startReceivedBytes"
            Log.i("CrumbT10", result)

            check(percentile(starts, 0.95) <= 5.0) { result }
            check(startWriteBytes == null || startWriteBytes == 0L) { result }
            check(startStorageBytes == 0L) { result }
            check(startTransmittedBytes == 0L && startReceivedBytes == 0L) { result }
            check(percentile(form, 0.95) <= 120.0) { result }
            check(percentile(diagnostics, 0.95) <= 500.0) { result }
            check(percentile(screenshot, 0.95) <= 750.0) { result }
            check(retainedMemoryBytes <= 20L * 1_024 * 1_024) { result }
        } finally {
            CrumbQualityInstrumentation.observe(null)
        }
    }

    private fun tagged(value: String): Matcher<View> = withTagValue(equalTo(value))

    private fun bringAppToForeground() {
        executeShell(
            "am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER " +
                "-f 0x10200000 -n dev.crumb.nativepoc.android/dev.crumb.demo.MainActivity",
        )
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private fun executeShell(command: String) {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand(command)
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { stream ->
            val buffer = ByteArray(1_024)
            while (stream.read(buffer) >= 0) Unit
        }
    }

    private fun waitForQualityEvent(
        events: List<CrumbQualityEvent>,
        kind: CrumbQualityEventKind,
        count: Int,
        timeoutMillis: Long = 15_000,
    ) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        do {
            if (synchronized(events) { events.count { it.kind == kind } } >= count) return
            Thread.sleep(10)
        } while (System.currentTimeMillis() < deadline)
        throw AssertionError("Timed out waiting for $kind measurement $count")
    }

    private fun samples(
        events: List<CrumbQualityEvent>,
        kind: CrumbQualityEventKind,
    ): List<Double> = synchronized(events) {
        events.filter { it.kind == kind }.map { it.elapsedMilliseconds }
    }

    private fun percentile(values: List<Double>, fraction: Double): Double {
        check(values.isNotEmpty())
        val sorted = values.sorted()
        val index = (ceil(sorted.size * fraction).toInt() - 1).coerceIn(sorted.indices)
        return sorted[index]
    }

    private fun processWriteBytes(): Long? = runCatching {
        File("/proc/self/io").useLines { lines ->
            lines.first { it.startsWith("write_bytes:") }.substringAfter(':').trim().toLong()
        }
    }.getOrNull()

    private fun appStorageBytes(): Long {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        return listOf(context.filesDir, context.cacheDir, context.noBackupFilesDir)
            .distinctBy(File::getAbsolutePath)
            .sumOf(::directoryBytes)
    }

    private fun directoryBytes(file: File): Long = when {
        !file.exists() -> 0
        file.isFile -> file.length()
        else -> file.listFiles()?.sumOf(::directoryBytes) ?: 0
    }

    private fun trafficDelta(before: Long, after: Long): Long = when {
        before < 0 || after < 0 -> 0
        else -> (after - before).coerceAtLeast(0)
    }

    private fun waitFor(matcher: Matcher<View>, timeoutMillis: Long = 15_000) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        var lastFailure: Throwable? = null
        do {
            try {
                onView(matcher).check(matches(isDisplayed()))
                return
            } catch (failure: Throwable) {
                lastFailure = failure
            }
            Thread.sleep(100)
        } while (System.currentTimeMillis() < deadline)

        throw AssertionError("Timed out waiting for $matcher", lastFailure)
    }
}

@RunWith(AndroidJUnit4::class)
@LargeTest
class CrumbAccessibilityUiTest {
    private lateinit var scenario: ActivityScenario<MainActivity>

    @Before
    fun launchWithAccessibleAppearance() {
        executeShell("settings put system accelerometer_rotation 0")
        executeShell("settings put system user_rotation 0")
        executeShell("settings put system font_scale 2.0")
        executeShell("cmd uimode night yes")
        Thread.sleep(750)
        scenario = ActivityScenario.launch(MainActivity::class.java)
        Thread.sleep(500)
        scenario.onActivity { activity ->
            val nightMode = activity.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK
            check(nightMode == android.content.res.Configuration.UI_MODE_NIGHT_YES)
            check(activity.resources.configuration.fontScale >= 1.9f)
            val reportButton = activity.window.decorView.findViewWithTag<View>(
                "demo.report-problem",
            )
            val scrollView = reportButton.parent.parent as android.widget.ScrollView
            scrollView.scrollTo(0, reportButton.bottom)
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        waitFor(tagged("demo.report-problem"))
    }

    @After
    fun restoreAppearance() {
        if (::scenario.isInitialized) scenario.close()
        executeShell("settings put system font_scale 1.0")
        executeShell("cmd uimode night no")
        Thread.sleep(750)
    }

    @Test
    fun darkAppearanceAndLargestTextKeepActionsReachable() {
        scenario.onActivity { activity ->
            check(CrumbReporter.show(activity)) {
                "Reporter did not open in dark appearance with largest text"
            }
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        waitFor(tagged("crumb.description"))
        waitFor(withContentDescription("Masked screenshot preview"))
        onView(tagged("crumb.description")).perform(replaceText("Accessible report"))
        closeSoftKeyboard()
        waitFor(allOf(tagged("crumb.review-draft"), isEnabled()))
        onView(tagged("crumb.review-draft")).perform(scrollTo(), click())
        waitFor(withText("Review"))
        onView(tagged("crumb.submit-report")).perform(scrollTo()).check(matches(isDisplayed()))
        pressBack()
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        if (isViewDisplayed(tagged("crumb.description"))) {
            onView(withContentDescription("Close report")).perform(directClick())
            onView(withText("Discard report")).perform(directClick())
        }
        waitFor(tagged("demo.report-problem"))
    }

    private fun tagged(value: String): Matcher<View> = withTagValue(equalTo(value))

    private fun executeShell(command: String) {
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand(command)
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { stream ->
            val buffer = ByteArray(1_024)
            while (stream.read(buffer) >= 0) Unit
        }
    }

    private fun waitFor(matcher: Matcher<View>, timeoutMillis: Long = 15_000) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        var lastFailure: Throwable? = null
        do {
            try {
                onView(matcher).check(matches(isDisplayed()))
                return
            } catch (failure: Throwable) {
                lastFailure = failure
            }
            Thread.sleep(100)
        } while (System.currentTimeMillis() < deadline)
        throw AssertionError("Timed out waiting for $matcher", lastFailure)
    }
}
