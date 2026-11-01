package dev.crumb.ui

import android.graphics.Rect
import android.graphics.RectF
import android.view.View

internal object CrumbScreenshotMaskBounds {
    fun calculate(view: View, root: View): Rect {
        val corners = floatArrayOf(
            0f, 0f,
            view.width.toFloat(), 0f,
            view.width.toFloat(), view.height.toFloat(),
            0f, view.height.toFloat(),
        )
        var current = view
        while (current !== root) {
            val parent = current.parent as? View ?: return Rect(0, 0, root.width, root.height)
            current.matrix.mapPoints(corners)
            val offsetX = current.left.toFloat() - parent.scrollX.toFloat()
            val offsetY = current.top.toFloat() - parent.scrollY.toFloat()
            for (index in corners.indices step 2) {
                corners[index] += offsetX
                corners[index + 1] += offsetY
            }
            current = parent
        }
        if (corners.any { !it.isFinite() }) return Rect(0, 0, root.width, root.height)

        // Bound only after mapping every corner, retaining ancestor transforms and scroll.
        // Clip before rounding so even extreme finite transforms cannot overflow integer bounds.
        val width = root.width.toFloat()
        val height = root.height.toFloat()
        val bounds = RectF(
            minOf(corners[0], corners[2], corners[4], corners[6]).coerceIn(0f, width),
            minOf(corners[1], corners[3], corners[5], corners[7]).coerceIn(0f, height),
            maxOf(corners[0], corners[2], corners[4], corners[6]).coerceIn(0f, width),
            maxOf(corners[1], corners[3], corners[5], corners[7]).coerceIn(0f, height),
        )
        val rounded = Rect()
        bounds.roundOut(rounded)
        rounded.inset(-3, -3)
        return rounded
    }
}
