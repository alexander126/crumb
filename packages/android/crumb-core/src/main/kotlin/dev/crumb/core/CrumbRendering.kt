package dev.crumb.core

import org.json.JSONObject

/** The UI observer supplies a bounded numeric snapshot; the UI observer owns the provider lifecycle. */
object CrumbRenderingEvidence {
    @Volatile var provider: ((Boolean) -> String?)? = null
    fun snapshot(settings: CrumbReportSettings): String? {
        val allowed = settings.diagnostics.renderingEnabled && CrumbEvidenceCategory.PERFORMANCE in settings.evidence
        val value = provider?.invoke(allowed)
        return if (allowed) validate(value) else null
    }

    fun validate(input: String?): String? = runCatching {
        require(input != null && input.length <= 2048)
        val v = JSONObject(input)
        val keys = setOf("source", "sample_count", "slow_frame_count", "mean_frame_ms", "max_frame_ms", "gpu_sample_count", "mean_gpu_ms", "max_gpu_ms", "last_frame_age_ms")
        require(v.keys().asSequence().all { it in keys } && v.getString("source") == "android_frame_metrics")
        val count = v.getInt("sample_count"); val slow = v.getInt("slow_frame_count"); val gpu = v.getInt("gpu_sample_count")
        require(gpu > 0 || (!v.has("mean_gpu_ms") && !v.has("max_gpu_ms")))
        require(count in 1..5000 && slow in 0..count && gpu in 0..count)
        for (key in listOf("sample_count", "slow_frame_count", "gpu_sample_count")) require(v.get(key) is Number && v.getDouble(key) == v.getInt(key).toDouble())
        for (key in listOf("mean_frame_ms", "max_frame_ms", "last_frame_age_ms") + if (gpu > 0) listOf("mean_gpu_ms", "max_gpu_ms") else emptyList()) {
            require(v.get(key) is Number)
            val n = v.getDouble(key); require(n.isFinite() && n in 0.0..5000.0)
        }
        require(v.getDouble("max_frame_ms") >= v.getDouble("mean_frame_ms"))
        require(v.getDouble("last_frame_age_ms") < 5000)
        require(gpu == 0 || v.getDouble("max_gpu_ms") >= v.getDouble("mean_gpu_ms"))
        v.toString()
    }.getOrNull()
}
