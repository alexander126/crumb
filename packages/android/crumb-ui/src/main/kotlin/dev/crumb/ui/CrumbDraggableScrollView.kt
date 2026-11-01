package dev.crumb.ui

import android.content.Context
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.widget.ScrollView
import kotlin.math.abs
import kotlin.math.max

/** A reporter sheet's header tracks downward drags without taking over content scrolling. */
internal class CrumbDraggableScrollView(
    context: Context,
    private val canDismiss: () -> Boolean,
    private val onDismissRequested: () -> Unit,
) : ScrollView(context) {
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val density = resources.displayMetrics.density
    private var startX = 0f
    private var startY = 0f
    private var startTranslation = 0f
    private var eligible = false
    private var dragging = false
    private var velocityTracker: VelocityTracker? = null

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                startTranslation = translationY
                startX = event.rawX
                startY = event.rawY
                // Leave the description, screenshot, and attachment scroll gestures alone.
                eligible = event.y <= 92 * density && !canScrollVertically(-1) && canDismiss()
                dragging = false
                velocityTracker?.recycle()
                velocityTracker = if (eligible) VelocityTracker.obtain() else null
                trackVelocity(event)
            }
            MotionEvent.ACTION_MOVE -> {
                if (beginDragIfNeeded(event)) return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (!dragging && translationY > 0) restorePosition()
                clearDrag()
            }
        }
        return super.onInterceptTouchEvent(event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        // Headers made of non-clickable labels route straight here, without a
        // child touch target for onInterceptTouchEvent's subsequent MOVE events.
        if (!dragging && event.actionMasked == MotionEvent.ACTION_MOVE) beginDragIfNeeded(event)
        if (!dragging) {
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                if (translationY > 0) restorePosition()
            }
            return super.onTouchEvent(event)
        }
        trackVelocity(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                // Raw coordinates stay stable while this view moves with the finger.
                translationY = max(0f, startTranslation + event.rawY - startY)
            }
            MotionEvent.ACTION_UP -> {
                velocityTracker?.computeCurrentVelocity(1000)
                val velocity = velocityTracker?.yVelocity ?: 0f
                val dismiss = canDismiss() && (
                    translationY > max(72 * density, height * 0.2f) ||
                        (translationY > 20 * density && velocity > 650 * density)
                    )
                restorePosition()
                clearDrag()
                if (dismiss) onDismissRequested()
            }
            MotionEvent.ACTION_CANCEL -> {
                restorePosition()
                clearDrag()
            }
        }
        return true
    }

    private fun restorePosition() {
        animate().translationY(0f).setDuration(200).start()
    }

    private fun beginDragIfNeeded(event: MotionEvent): Boolean {
        val distance = event.rawY - startY
        if (!eligible || !canDismiss() || distance <= touchSlop || distance <= abs(event.rawX - startX)) return false
        animate().cancel()
        startTranslation = translationY
        dragging = true
        parent?.requestDisallowInterceptTouchEvent(true)
        return true
    }

    private fun trackVelocity(event: MotionEvent) {
        val movement = MotionEvent.obtain(event)
        movement.offsetLocation(event.rawX - event.x, event.rawY - event.y)
        velocityTracker?.addMovement(movement)
        movement.recycle()
    }

    private fun clearDrag() {
        dragging = false
        eligible = false
        velocityTracker?.recycle()
        velocityTracker = null
        parent?.requestDisallowInterceptTouchEvent(false)
    }

    override fun onDetachedFromWindow() {
        animate().cancel()
        clearDrag()
        super.onDetachedFromWindow()
    }
}
