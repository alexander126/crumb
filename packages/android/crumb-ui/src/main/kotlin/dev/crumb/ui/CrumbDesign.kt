package dev.crumb.ui

import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.widget.Button
import android.widget.TextView
import dev.crumb.core.CrumbTheme

internal object CrumbDesign {
    var INK = 0xFF16181D.toInt()
        private set
    var ACCENT = 0xFF0FB489.toInt()
        private set
    var ACCENT_DARK = 0xFF077056.toInt()
        private set
    var ACTION_FILL = 0xFF0FB489.toInt()
        private set
    var CANVAS = 0xFFFBFBFD.toInt()
        private set
    var SURFACE = 0xFFF7F8FB.toInt()
        private set
    var MUTED_SURFACE = 0xFFEEF0F5.toInt()
        private set
    var DIVIDER = 0xFFE4E6EC.toInt()
        private set
    var SECONDARY_TEXT = 0xFF4C535F.toInt()
        private set
    var MUTED_TEXT = 0xFF6E7684.toInt()
        private set
    var TERTIARY_TEXT = 0xFF9AA1AE.toInt()
        private set
    var DISABLED = 0xFFC6CBD5.toInt()
        private set
    var DANGER = 0xFFD2543C.toInt()
        private set
    var PALE_DANGER = 0xFFFBEBE7.toInt()
        private set
    var WARNING = 0xFF9A6500.toInt()
        private set
    var PALE_WARNING = 0xFFFBF3E2.toInt()
        private set
    var DARK_SURFACE = 0xFF22252C.toInt()
        private set
    var TEXT_ON_DARK = 0xFFD5D8E0.toInt()
        private set
    var SELECTED_FILL = 0xFF16181D.toInt()
        private set
    var TEXT_ON_SELECTED = Color.WHITE
        private set
    val MARK_BACKGROUND = 0xFF16181D.toInt()

    fun applyAppearance(context: Context, theme: CrumbTheme = CrumbTheme.SYSTEM) {
        val systemIsDark = context.resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val isDark = when (theme) {
            CrumbTheme.SYSTEM -> systemIsDark
            CrumbTheme.LIGHT -> false
            CrumbTheme.DARK -> true
        }
        INK = if (isDark) 0xFFF4F5F7.toInt() else 0xFF16181D.toInt()
        ACCENT = if (isDark) 0xFF2DD4A7.toInt() else 0xFF0FB489.toInt()
        ACCENT_DARK = if (isDark) 0xFF72E2C1.toInt() else 0xFF077056.toInt()
        ACTION_FILL = if (isDark) 0xFF2DD4A7.toInt() else 0xFF0FB489.toInt()
        CANVAS = if (isDark) 0xFF121419.toInt() else 0xFFFBFBFD.toInt()
        SURFACE = if (isDark) 0xFF191C22.toInt() else 0xFFF7F8FB.toInt()
        MUTED_SURFACE = if (isDark) 0xFF22262E.toInt() else 0xFFEEF0F5.toInt()
        DIVIDER = if (isDark) 0xFF323842.toInt() else 0xFFE4E6EC.toInt()
        SECONDARY_TEXT = if (isDark) 0xFFB9C0CB.toInt() else 0xFF4C535F.toInt()
        MUTED_TEXT = if (isDark) 0xFFA3ACB9.toInt() else 0xFF6E7684.toInt()
        TERTIARY_TEXT = if (isDark) 0xFF8993A2.toInt() else 0xFF9AA1AE.toInt()
        DISABLED = if (isDark) 0xFF59616D.toInt() else 0xFFC6CBD5.toInt()
        DANGER = if (isDark) 0xFFFF8D78.toInt() else 0xFFD2543C.toInt()
        PALE_DANGER = if (isDark) 0xFF3A201B.toInt() else 0xFFFBEBE7.toInt()
        WARNING = if (isDark) 0xFFF4C15D.toInt() else 0xFF9A6500.toInt()
        PALE_WARNING = if (isDark) 0xFF352B17.toInt() else 0xFFFBF3E2.toInt()
        DARK_SURFACE = if (isDark) 0xFF090B0F.toInt() else 0xFF22252C.toInt()
        TEXT_ON_DARK = if (isDark) 0xFFE4E7ED.toInt() else 0xFFD5D8E0.toInt()
        SELECTED_FILL = if (isDark) 0xFF2F3540.toInt() else 0xFF16181D.toInt()
        TEXT_ON_SELECTED = Color.WHITE
    }

    fun dp(context: Context, value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()

    fun rounded(
        context: Context,
        fill: Int,
        radius: Int = 14,
        stroke: Int = DIVIDER,
        strokeWidth: Int = 1,
    ) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(fill)
        cornerRadius = dp(context, radius).toFloat()
        if (strokeWidth > 0) setStroke(dp(context, strokeWidth), stroke)
    }

    fun sectionLabel(context: Context, value: String) = TextView(context).apply {
        text = value.uppercase()
        textSize = 12f
        setTextColor(MUTED_TEXT)
        setTypeface(typeface, Typeface.BOLD)
        letterSpacing = 0.04f
    }

    fun stylePrimaryButton(context: Context, button: Button, title: String) {
        button.text = title
        button.isAllCaps = false
        button.textSize = 15f
        button.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        button.setTextColor(ColorStateList(
            arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(TERTIARY_TEXT, Color.WHITE),
        ))
        button.gravity = Gravity.CENTER
        button.minHeight = dp(context, 50)
        button.backgroundTintList = null
        button.background = StateListDrawable().apply {
            addState(
                intArrayOf(-android.R.attr.state_enabled),
                rounded(context, MUTED_SURFACE, radius = 99, strokeWidth = 0),
            )
            addState(
                intArrayOf(),
                rounded(context, ACTION_FILL, radius = 99, strokeWidth = 0),
            )
        }
    }
}
