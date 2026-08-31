package dev.crumb.ui

import android.app.Activity
import android.graphics.Color
import android.view.View
import android.widget.FrameLayout
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbPrivacyOptions
import dev.crumb.core.CrumbScreenshotMaskingState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import java.security.MessageDigest

@RunWith(RobolectricTestRunner::class)
class CrumbScreenshotArtifactTest {
    @Test
    fun customMaskIsAppliedBeforeTheBoundedPngIsHashed() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().visible().get()
        val root = FrameLayout(activity).apply { setBackgroundColor(Color.RED) }
        val sensitive = View(activity).apply {
            setBackgroundColor(Color.GREEN)
            maskInCrumbScreenshots()
        }
        root.addView(sensitive, FrameLayout.LayoutParams(160, 80).apply {
            leftMargin = 40
            topMargin = 120
        })
        activity.setContentView(root)
        val exactWidth = View.MeasureSpec.makeMeasureSpec(240, View.MeasureSpec.EXACTLY)
        val exactHeight = View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY)
        activity.window.decorView.measure(exactWidth, exactHeight)
        activity.window.decorView.layout(0, 0, 240, 480)
        root.measure(exactWidth, exactHeight)
        root.layout(0, 0, 240, 480)
        assertTrue("sensitive view must be shown for capture", sensitive.isShown)

        val artifact = CrumbScreenshotArtifactPipeline.capture(
            activity = activity,
            capture = CrumbCaptureOptions(
                maximumScreenshotDimension = 320,
                maximumScreenshotBytes = 262_144,
            ),
            privacy = CrumbPrivacyOptions(
                maskAllTextInputs = false,
                maskScreenshotsBeforeUpload = false,
            ),
        )

        assertNotNull(artifact)
        artifact!!
        assertTrue(maxOf(artifact.preview.width, artifact.preview.height) <= 320)
        assertTrue(artifact.encodedBytes.size <= 262_144)
        assertEquals(artifact.encodedBytes.size.toLong(), artifact.manifest.byteSize)
        assertEquals("image/png", artifact.manifest.mimeType)
        assertEquals("masked", artifact.manifest.redactionState)
        assertEquals(CrumbScreenshotMaskingState.APPLIED, artifact.maskingState)
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(artifact.encodedBytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        assertEquals(digest, artifact.manifest.sha256)

        val decorLocation = IntArray(2).also(activity.window.decorView.rootView::getLocationInWindow)
        val sensitiveLocation = IntArray(2).also(sensitive::getLocationInWindow)
        val scale = artifact.preview.width.toFloat() / activity.window.decorView.rootView.width
        val sampleX = ((sensitiveLocation[0] - decorLocation[0] + sensitive.width / 2) * scale).toInt()
        val sampleY = ((sensitiveLocation[1] - decorLocation[1] + sensitive.height / 2) * scale).toInt()
        val sample = artifact.preview.getPixel(sampleX, sampleY)
        val message = "sample=($sampleX,$sampleY) rgba=" +
            "${Color.red(sample)},${Color.green(sample)},${Color.blue(sample)},${Color.alpha(sample)}"
        assertTrue(message, Color.red(sample) < 8)
        assertTrue(message, Color.green(sample) < 8)
        assertTrue(message, Color.blue(sample) < 8)
        assertEquals(255, Color.alpha(sample))
    }
}
