package dev.crumb.ui

import android.app.Activity
import android.app.Application
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.FrameMetrics
import android.view.Window
import dev.crumb.core.*
import java.lang.ref.WeakReference

internal class RenderingBuffer {
    private class Bucket(var second: Long = -1, var count: Int = 0, var slow: Int = 0,
        var sum: Double = 0.0, var maximum: Double = 0.0, var gpuCount: Int = 0, var gpuSum: Double = 0.0, var gpuMax: Double = 0.0)
    private val buckets = Array(5) { Bucket() }
    private var last = -1L
    @Synchronized fun clear() { for (i in buckets.indices) buckets[i] = Bucket(); last = -1 }
    @Synchronized fun record(now: Long, frame: Double, budget: Double, gpu: Double?) {
        if (now < 0 || !frame.isFinite() || frame <= 0 || frame > 5000 || !budget.isFinite() || budget <= 0) return
        val second = now / 1000; val index = (second % 5).toInt()
        if (buckets[index].second != second) buckets[index] = Bucket(second)
        val bucket = buckets[index]
        if (bucket.count >= 1000) return
        bucket.count++; bucket.sum += frame; bucket.maximum = maxOf(bucket.maximum, frame)
        if (frame > budget * 1.5) bucket.slow++
        if (gpu != null && gpu.isFinite() && gpu in 0.0..5000.0) { bucket.gpuCount++; bucket.gpuSum += gpu; bucket.gpuMax = maxOf(bucket.gpuMax, gpu) }
        last = now
    }
    @Synchronized fun snapshot(now: Long = SystemClock.elapsedRealtime()): CrumbRenderingSnapshot? {
        if (last < 0 || now < last || now - last >= 5000) return null
        val active = buckets.filter { it.second > now / 1000 - 5 && it.second <= now / 1000 }
        val count = active.sumOf { it.count }; if (count == 0) return null
        val gpuCount = active.sumOf { it.gpuCount }
        return CrumbRenderingSnapshot("android_frame_metrics", count, active.sumOf { it.slow }, active.sumOf { it.sum } / count,
            active.maxOf { it.maximum }, gpuCount, if (gpuCount > 0) active.sumOf { it.gpuSum } / gpuCount else null,
            if (gpuCount > 0) active.maxOf { it.gpuMax } else null, (now - last).toDouble())
    }
}

internal object RenderingMonitor : Application.ActivityLifecycleCallbacks {
    private val buffer = RenderingBuffer()
    private var installed = false
    private var window = WeakReference<Window>(null)
    private val listener = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
        val settings = runCatching { Crumb.reportSettings() }.getOrNull()
        if (settings?.diagnostics?.renderingEnabled != true || CrumbEvidenceCategory.PERFORMANCE !in settings.evidence) {
            buffer.clear()
        } else if (metrics.getMetric(FrameMetrics.FIRST_DRAW_FRAME) != 1L) {
            val total = metrics.getMetric(FrameMetrics.TOTAL_DURATION) / 1_000_000.0
            val deadline = if (Build.VERSION.SDK_INT >= 31) metrics.getMetric(FrameMetrics.DEADLINE) / 1_000_000.0 else 0.0
            val refresh = window.get()?.decorView?.display?.refreshRate?.toDouble() ?: 60.0
            val budget = if (deadline > 0) deadline else 1000.0 / refresh.coerceAtLeast(1.0)
            val gpu = if (Build.VERSION.SDK_INT >= 31) metrics.getMetric(FrameMetrics.GPU_DURATION).takeIf { it >= 0 }?.div(1_000_000.0) else null
            buffer.record(SystemClock.elapsedRealtime(), total, budget, gpu)
        }
    }
    fun install(application: Application, activity: Activity? = null) {
        if (!Crumb.reportSettings().diagnostics.renderingEnabled) return
        if (!installed) { installed = true; application.registerActivityLifecycleCallbacks(this); CrumbRenderingEvidence.provider = { allowed -> if (allowed) buffer.snapshot()?.encode()?.toString() else { buffer.clear(); null } } }
        activity?.let { onActivityResumed(it) }
    }
    override fun onActivityResumed(activity: Activity) {
        if (window.get() === activity.window) return
        detach(); window = WeakReference(activity.window)
        activity.window.addOnFrameMetricsAvailableListener(listener, Handler(Looper.getMainLooper()))
    }
    private fun detach() { window.get()?.removeOnFrameMetricsAvailableListener(listener); window.clear(); buffer.clear() }
    override fun onActivityPaused(activity: Activity) { if (window.get() === activity.window) detach() }
    override fun onActivityDestroyed(activity: Activity) { if (window.get() === activity.window) detach() }
    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
}
