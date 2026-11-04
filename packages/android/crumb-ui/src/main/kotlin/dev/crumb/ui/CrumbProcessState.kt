package dev.crumb.ui

import android.app.ActivityManager
import android.content.Context
import java.io.File

/**
 * The process's own foreground state.
 *
 * `registerActivityLifecycleCallbacks` does not replay events, so a host that
 * installs after its Activity has already resumed never receives the resume
 * that would start report delivery. Delivery needs no Activity instance - only
 * the knowledge that the application is in front of the user - so it is started
 * from the process state instead.
 */
internal object CrumbProcessState {
    /**
     * Foreground-UI importance only. A foreground *service* is deliberately not
     * foreground here: delivery stays tied to the application being in front of
     * the user.
     */
    @JvmSynthetic
    fun isForegroundImportance(importance: Int): Boolean =
        importance in 1..ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND

    /**
     * The report queue is single-process, and so is the reporter that writes to
     * it. The rule is duplicated here rather than shared from crumb-core
     * because crumb-core has no room in its binary budget for the seam; both
     * sides compare the process name with the package name and treat an
     * unnamable process as the main one.
     */
    @JvmSynthetic
    fun isMainProcess(
        context: Context,
        processName: String? = currentProcessName(),
    ): Boolean = processName == null || processName == context.packageName

    /** Null when the process cannot be named. No Context, no permission. */
    private fun currentProcessName(): String? = try {
        File("/proc/self/cmdline").readText().substringBefore('\u0000').trim().ifEmpty { null }
    } catch (_: Exception) {
        null
    }

    @JvmSynthetic
    fun isForeground(context: Context): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        return runCatching {
            ActivityManager.getMyMemoryState(state)
            isForegroundImportance(state.importance)
        }.getOrDefault(false)
    }
}
