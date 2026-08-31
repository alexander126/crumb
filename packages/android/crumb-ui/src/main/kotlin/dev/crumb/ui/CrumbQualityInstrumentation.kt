package dev.crumb.ui

/** Release-QA timing boundaries. Dormant unless a host explicitly installs an observer. */
enum class CrumbQualityEventKind {
    FORM_READY,
    DIAGNOSTICS_READY,
    SCREENSHOT_READY,
    REPORTER_CLOSED,
}

data class CrumbQualityEvent(
    val kind: CrumbQualityEventKind,
    val elapsedMilliseconds: Double,
)

object CrumbQualityInstrumentation {
    @Volatile
    private var observer: ((CrumbQualityEvent) -> Unit)? = null

    /** Intended for Crumb's release harness, not application analytics. */
    @JvmSynthetic
    fun observe(observer: ((CrumbQualityEvent) -> Unit)?) {
        this.observer = observer
    }

    internal fun record(
        kind: CrumbQualityEventKind,
        startedAtNanos: Long,
    ) {
        val activeObserver = observer ?: return
        val elapsed = (android.os.SystemClock.elapsedRealtimeNanos() - startedAtNanos) / 1_000_000.0
        activeObserver(CrumbQualityEvent(kind, elapsed))
    }
}
