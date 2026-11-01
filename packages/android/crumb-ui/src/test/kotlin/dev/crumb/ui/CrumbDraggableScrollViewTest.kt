package dev.crumb.ui

import android.app.Activity
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
class CrumbDraggableScrollViewTest {
    @Test
    fun headerTracksTheFingerAndRequestsDismissal() {
        val fixture = sheet()
        fixture.touch(MotionEvent.ACTION_DOWN, 20f, 0)
        fixture.touch(MotionEvent.ACTION_MOVE, 160f, 500)
        assertEquals(140f, fixture.view.translationY, 1f)
        fixture.touch(MotionEvent.ACTION_MOVE, 220f, 1000)
        assertEquals(200f, fixture.view.translationY, 1f)
        fixture.touch(MotionEvent.ACTION_UP, 220f, 1500)
        assertEquals(1, fixture.dismissals)
    }

    @Test
    fun shortOrCancelledDragsReturnWithoutDismissing() {
        for (ending in listOf(MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL)) {
            val fixture = sheet()
            fixture.touch(MotionEvent.ACTION_DOWN, 20f, 0)
            fixture.touch(MotionEvent.ACTION_MOVE, 60f, 500)
            fixture.touch(ending, 60f, 1500)
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
            assertEquals(0, fixture.dismissals)
            assertEquals(0f, fixture.view.translationY, 1f)
        }
    }

    @Test
    fun contentScrollingAndSavingDoNotStartASheetDrag() {
        for (fixture in listOf(sheet(startAllowed = false), sheet())) {
            val start = if (fixture.allowed) 300f else 20f
            fixture.touch(MotionEvent.ACTION_DOWN, start, 0)
            fixture.touch(MotionEvent.ACTION_MOVE, start + 200, 500)
            fixture.touch(MotionEvent.ACTION_UP, start + 200, 1500)
            assertEquals(0, fixture.dismissals)
            assertEquals(0f, fixture.view.translationY, 1f)
        }
    }

    @Test
    fun touchingChildContentDoesNotFreezeAReturningSheet() {
        val fixture = sheet()
        fixture.view.getChildAt(0).isClickable = true
        fixture.view.translationY = 100f
        fixture.view.animate().translationY(0f).setDuration(200).start()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(50))
        fixture.touch(MotionEvent.ACTION_DOWN, 300f, 100)
        fixture.touch(MotionEvent.ACTION_UP, 300f, 200)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertEquals(0f, fixture.view.translationY, 1f)
        assertEquals(0, fixture.dismissals)
    }

    private fun sheet(startAllowed: Boolean = true): Fixture {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val fixture = Fixture(startAllowed)
        val root = FrameLayout(activity)
        fixture.view = CrumbDraggableScrollView(activity, { fixture.allowed }, { fixture.dismissals++ })
        fixture.view.addView(View(activity), FrameLayout.LayoutParams(400, 1200))
        root.addView(fixture.view, FrameLayout.LayoutParams(400, 600))
        activity.setContentView(root)
        val width = View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY)
        val height = View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY)
        root.measure(width, height)
        root.layout(0, 0, 400, 900)
        fixture.root = root
        assertTrue(fixture.view.isShown)
        return fixture
    }

    private class Fixture(val allowed: Boolean) {
        lateinit var view: CrumbDraggableScrollView
        lateinit var root: FrameLayout
        var dismissals = 0

        fun touch(action: Int, y: Float, time: Long) {
            val event = MotionEvent.obtain(0, time, action, 100f, y, 0)
            root.dispatchTouchEvent(event)
            event.recycle()
        }
    }
}
