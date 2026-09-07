package dev.crumb.ui

import org.json.JSONObject

/** Immutable, bounded numeric evidence supplied by the platform observer. */
internal class CrumbRenderingSnapshot(val source: String, val sampleCount: Int, val slowFrameCount: Int,
    val meanFrameMs: Double, val maxFrameMs: Double, val gpuSampleCount: Int,
    val meanGpuMs: Double?, val maxGpuMs: Double?, val lastFrameAgeMs: Double) {
    fun encode(): JSONObject = JSONObject().apply {
        put("source", source); put("sample_count", sampleCount); put("slow_frame_count", slowFrameCount)
        put("mean_frame_ms", meanFrameMs); put("max_frame_ms", maxFrameMs); put("gpu_sample_count", gpuSampleCount)
        meanGpuMs?.let { put("mean_gpu_ms", it) }; maxGpuMs?.let { put("max_gpu_ms", it) }
        put("last_frame_age_ms", lastFrameAgeMs)
    }
}
