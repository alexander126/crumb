package dev.crumb.ui

import android.app.ActivityManager
import android.content.Context

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

    @JvmSynthetic
    fun isForeground(context: Context): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        return runCatching {
            ActivityManager.getMyMemoryState(state)
            isForegroundImportance(state.importance)
        }.getOrDefault(false)
    }
}
