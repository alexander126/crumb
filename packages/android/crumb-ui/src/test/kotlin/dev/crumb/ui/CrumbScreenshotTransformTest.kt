package dev.crumb.ui

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbPrivacyOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [26, 35])
class CrumbScreenshotTransformTest {
    @Test
    fun masksTheWholeScaledHostMarkedViewWithAutomaticMaskingDisabled() {
        assertMasksSensitivePixels { _, sensitive ->
            sensitive.pivotX = 0f
            sensitive.pivotY = 0f
            sensitive.scaleX = 2f
            sensitive.scaleY = 2f
        }
    }

    @Test
    fun masksRotatedAutomaticTextInputsWithFractionalTranslation() {
        assertMasksSensitivePixels(automaticTextInput = true) { _, sensitive ->
            sensitive.pivotX = 0f
            sensitive.pivotY = 0f
            sensitive.rotation = 37f
            sensitive.translationX = 10.5f
            sensitive.translationY = -7.25f
        }
    }

    @Test
    fun masksAutomaticTextInputsInsideTransformedAndScrolledAncestors() {
        assertMasksSensitivePixels(automaticTextInput = true) { ancestor, sensitive ->
            ancestor.pivotX = 13f
            ancestor.pivotY = 27f
            ancestor.scaleX = 1.4f
            ancestor.scaleY = 0.9f
            ancestor.rotation = -18f
            ancestor.translationX = 0.3f
            ancestor.translationY = 0.6f
            ancestor.scrollTo(11, 7)
            sensitive.rotation = 9f
        }
    }

    @Test
    fun masksNegativeScaleAroundANoncentralPivot() {
        assertMasksSensitivePixels { _, sensitive ->
            sensitive.pivotX = 15.75f
            sensitive.pivotY = 12.25f
            sensitive.scaleX = -1.8f
            sensitive.scaleY = 1.4f
            sensitive.rotation = 9f
            sensitive.translationX = 20.5f
            sensitive.translationY = 3.25f
        }
    }

    @Test
    fun clipsTransformedMaskBoundsAtTheScreenshotEdge() {
        assertMasksSensitivePixels { ancestor, sensitive ->
            ancestor.layoutParams = FrameLayout.LayoutParams(200, 200).apply {
                leftMargin = 0
                topMargin = 40
            }
            sensitive.pivotX = 0f
            sensitive.pivotY = 0f
            sensitive.translationX = -75.25f
            sensitive.scaleX = 1.6f
            sensitive.scaleY = 1.6f
        }
    }

    private fun assertMasksSensitivePixels(
        automaticTextInput: Boolean = false,
        configure: (FrameLayout, View) -> Unit,
    ) {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val content = FrameLayout(activity).apply { setBackgroundColor(Color.RED) }
        val ancestor = FrameLayout(activity).apply {
            clipChildren = false
            clipToPadding = false
        }
        val sensitive = if (automaticTextInput) EditText(activity) else View(activity)
        sensitive.setBackgroundColor(Color.GREEN)
        if (!automaticTextInput) sensitive.maskInCrumbScreenshots()
        ancestor.addView(sensitive, FrameLayout.LayoutParams(60, 40).apply {
            leftMargin = 40
            topMargin = 40
        })
        content.addView(ancestor, FrameLayout.LayoutParams(200, 200).apply {
            leftMargin = 40
            topMargin = 120
        })
        configure(ancestor, sensitive)
        activity.setContentView(content)
        val widthSpec = View.MeasureSpec.makeMeasureSpec(320, View.MeasureSpec.EXACTLY)
        val heightSpec = View.MeasureSpec.makeMeasureSpec(640, View.MeasureSpec.EXACTLY)
        val root = activity.window.decorView.rootView
        root.measure(widthSpec, heightSpec)
        root.layout(0, 0, 320, 640)
        content.measure(widthSpec, heightSpec)
        content.layout(0, 0, 320, 640)

        // This synthetic reference stays in memory and is never encoded or made into an artifact.
        val reference = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        root.draw(Canvas(reference))
        val artifact = requireNotNull(CrumbScreenshotArtifactPipeline.capture(
            activity = activity,
            capture = CrumbCaptureOptions(maximumScreenshotDimension = 4_096),
            privacy = CrumbPrivacyOptions(
                maskAllTextInputs = automaticTextInput,
                maskScreenshotsBeforeUpload = false,
            ),
        ))
        val encoded = requireNotNull(BitmapFactory.decodeByteArray(
            artifact.encodedBytes,
            0,
            artifact.encodedBytes.size,
        ))
        assertEquals(reference.width, encoded.width)
        assertEquals(reference.height, encoded.height)
        var sensitivePixels = 0
        var preservedSafePixels = 0
        for (y in 0 until reference.height) {
            for (x in 0 until reference.width) {
                val before = reference.getPixel(x, y)
                val after = encoded.getPixel(x, y)
                if (Color.green(before) > 0 && Color.blue(before) == 0) {
                    sensitivePixels += 1
                    assertEquals("sensitive pixel ($x,$y) remained visible", Color.BLACK, after)
                }
                if (before == Color.RED && after == Color.RED) preservedSafePixels += 1
            }
        }
        assertTrue("fixture must render sensitive content", sensitivePixels > 100)
        assertTrue("pixels outside the sensitive bounds must remain visible", preservedSafePixels > 1_000)
        assertEquals("masked", artifact.manifest.redactionState)
    }
}
