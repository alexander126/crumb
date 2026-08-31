package dev.crumb.ui

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import dev.crumb.core.CrumbArtifactManifest
import dev.crumb.core.CrumbCaptureOptions
import dev.crumb.core.CrumbPrivacyOptions
import dev.crumb.core.CrumbScreenshotMaskingState
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.WeakHashMap
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Registry for host-owned Android View, ComposeView, and WebView mask regions. */
object CrumbScreenshotMasking {
    private val maskedViews = WeakHashMap<View, Unit>()

    @JvmStatic
    @JvmOverloads
    fun setMasked(view: View, masked: Boolean = true) = synchronized(maskedViews) {
        if (masked) maskedViews[view] = Unit else maskedViews.remove(view)
    }

    internal fun isMasked(view: View): Boolean = synchronized(maskedViews) {
        maskedViews.containsKey(view)
    }
}

/** Marks this view's visible bounds as an opaque region in Crumb screenshots. */
fun View.maskInCrumbScreenshots(masked: Boolean = true) {
    CrumbScreenshotMasking.setMasked(this, masked)
}

internal data class CrumbScreenshotArtifact(
    val preview: Bitmap,
    val encodedBytes: ByteArray,
    val manifest: CrumbArtifactManifest,
    val maskingState: CrumbScreenshotMaskingState,
)

internal object CrumbScreenshotArtifactPipeline {
    /**
     * Copies the host window through SurfaceFlinger and performs masking, PNG encoding, and
     * hashing off the main thread. This keeps reporter presentation independent of screenshot
     * complexity while preserving the same fail-closed artifact path as synchronous capture.
     */
    fun captureAsync(
        activity: Activity,
        capture: CrumbCaptureOptions,
        privacy: CrumbPrivacyOptions,
        completion: (CrumbScreenshotArtifact?) -> Unit,
    ) {
        val root = activity.window.decorView.rootView
        if (root.width <= 0 || root.height <= 0) {
            completion(null)
            return
        }
        val plan = capturePlan(root, privacy)
        val bitmap = runCatching {
            Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        }.getOrElse {
            completion(null)
            return
        }
        val worker = HandlerThread("Crumb screenshot").apply { start() }
        val workerHandler = Handler(worker.looper)
        val mainHandler = Handler(Looper.getMainLooper())
        val finish: (CrumbScreenshotArtifact?) -> Unit = { artifact ->
            mainHandler.post { completion(artifact) }
            worker.quitSafely()
        }

        runCatching {
            PixelCopy.request(
                activity.window,
                bitmap,
                { result ->
                    val artifact = if (result == PixelCopy.SUCCESS) {
                        runCatching { createArtifact(bitmap, plan, capture) }.getOrNull()
                    } else {
                        null
                    }
                    finish(artifact)
                },
                workerHandler,
            )
        }.onFailure { finish(null) }
    }

    fun capture(
        activity: Activity,
        capture: CrumbCaptureOptions,
        privacy: CrumbPrivacyOptions,
    ): CrumbScreenshotArtifact? {
        return runCatching {
            val root = activity.window.decorView.rootView
            if (root.width <= 0 || root.height <= 0) return null

            val plan = capturePlan(root, privacy)
            val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            root.draw(canvas)
            createArtifact(bitmap, plan, capture)
        }.getOrNull()
    }

    private data class MaskRegion(
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
    )

    private data class CapturePlan(
        val maskingConfigured: Boolean,
        val maskRegions: List<MaskRegion>,
    )

    private fun capturePlan(root: View, privacy: CrumbPrivacyOptions): CapturePlan {
        val maskViews = sensitiveViews(root, privacy.maskAllTextInputs)
        val rootLocation = IntArray(2).also(root::getLocationInWindow)
        val regions = maskViews.mapNotNull { view ->
            if (
                view.visibility != View.VISIBLE || view.alpha <= 0f ||
                view.width <= 0 || view.height <= 0
            ) {
                return@mapNotNull null
            }
            val location = IntArray(2).also(view::getLocationInWindow)
            val left = location[0] - rootLocation[0] - 3
            val top = location[1] - rootLocation[1] - 3
            MaskRegion(left, top, left + view.width + 6, top + view.height + 6)
        }
        return CapturePlan(
            maskingConfigured = privacy.maskScreenshotsBeforeUpload ||
                privacy.maskAllTextInputs || maskViews.isNotEmpty(),
            maskRegions = regions,
        )
    }

    private fun createArtifact(
        bitmap: Bitmap,
        plan: CapturePlan,
        capture: CrumbCaptureOptions,
    ): CrumbScreenshotArtifact? {
        plan.maskRegions.forEach { region ->
            maskOpaque(bitmap, region.left, region.top, region.right, region.bottom)
        }
        val encoded = encode(
            bitmap = bitmap,
            maximumDimension = capture.maximumScreenshotDimension,
            maximumBytes = capture.maximumScreenshotBytes,
        ) ?: return null
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(encoded.bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val token = UUID.randomUUID().toString().replace("-", "")
        val maskingState = if (plan.maskingConfigured) {
            CrumbScreenshotMaskingState.APPLIED
        } else {
            CrumbScreenshotMaskingState.NOT_APPLICABLE
        }
        return CrumbScreenshotArtifact(
            preview = encoded.bitmap,
            encodedBytes = encoded.bytes,
            manifest = CrumbArtifactManifest(
                id = "art_$token",
                kind = "screenshot",
                mimeType = "image/png",
                byteSize = encoded.bytes.size.toLong(),
                sha256 = digest,
                redactionState = if (plan.maskingConfigured) "masked" else "not_applicable",
                uploadId = "upl_$token",
            ),
            maskingState = maskingState,
        )
    }

    private fun sensitiveViews(view: View, includeTextInputs: Boolean): List<View> {
        val matches = mutableListOf<View>()
        if (CrumbScreenshotMasking.isMasked(view) || (includeTextInputs && view is EditText)) {
            matches += view
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                matches += sensitiveViews(view.getChildAt(index), includeTextInputs)
            }
        }
        return matches
    }

    private fun maskOpaque(
        bitmap: Bitmap,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
    ) {
        val clippedLeft = left.coerceIn(0, bitmap.width)
        val clippedTop = top.coerceIn(0, bitmap.height)
        val clippedRight = right.coerceIn(clippedLeft, bitmap.width)
        val clippedBottom = bottom.coerceIn(clippedTop, bitmap.height)
        val width = clippedRight - clippedLeft
        if (width == 0 || clippedBottom == clippedTop) return
        val row = IntArray(width) { Color.BLACK }
        for (y in clippedTop until clippedBottom) {
            bitmap.setPixels(row, 0, width, clippedLeft, y, width, 1)
        }
    }

    private data class EncodedBitmap(val bitmap: Bitmap, val bytes: ByteArray)

    private fun encode(
        bitmap: Bitmap,
        maximumDimension: Int,
        maximumBytes: Int,
    ): EncodedBitmap? {
        var current = resized(bitmap, maximumDimension)
        repeat(10) {
            val bytes = ByteArrayOutputStream().use { stream ->
                if (!current.compress(Bitmap.CompressFormat.PNG, 100, stream)) return null
                stream.toByteArray()
            }
            if (bytes.size <= maximumBytes) return EncodedBitmap(current, bytes)

            val longest = max(current.width, current.height)
            if (current.width <= 160 || current.height <= 160) return null
            val ratio = sqrt(maximumBytes.toDouble() / bytes.size.toDouble()) * 0.9
            val nextMaximum = max(160, (longest * min(0.9, ratio)).toInt())
            if (nextMaximum >= longest) return null
            current = resized(current, nextMaximum)
        }
        return null
    }

    private fun resized(bitmap: Bitmap, maximumDimension: Int): Bitmap {
        val longest = max(bitmap.width, bitmap.height)
        if (longest <= maximumDimension) return bitmap
        val scale = maximumDimension.toFloat() / longest.toFloat()
        return Bitmap.createScaledBitmap(
            bitmap,
            max(1, (bitmap.width * scale).toInt()),
            max(1, (bitmap.height * scale).toInt()),
            true,
        )
    }
}
