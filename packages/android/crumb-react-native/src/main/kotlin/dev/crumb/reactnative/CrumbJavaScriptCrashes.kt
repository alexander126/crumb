package dev.crumb.reactnative

import android.content.Context
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbEvidenceCategory
import dev.crumb.core.CrumbJavaScriptFailureContext

/**
 * The React Native JavaScript crash handoff.
 *
 * This is the entry point `@crumbsdk/react-native` calls. It lives in
 * `crumb-react-native` rather than `crumb-core` so a native-only Android app
 * does not ship the handoff store, its recovery, or its failure-context
 * capture - roughly 81 KiB of class bytes it would never call.
 *
 * Both calls are no-ops unless Crumb has been started with
 * `diagnostics.javascriptCrashCaptureEnabled`.
 */
object CrumbJavaScriptCrashes {
    /** Synchronously accepts the adapter's sanitized JavaScript failure. */
    @JvmStatic
    fun record(context: Context, recordJson: String) {
        val settings = Crumb.javaScriptCrashSettings() ?: return
        val applicationContext = context.applicationContext
        val snapshot = runCatching {
            CrumbJavaScriptFailureContext.capture(applicationContext, settings)
        }.getOrNull()
        CrumbJavaScriptCrashStore(
            applicationContext.noBackupFilesDir.resolve("crumb/javascript-crashes"),
        ).record(
            recordJson,
            snapshot,
            settings.diagnostics.logs.enabled &&
                CrumbEvidenceCategory.LOGS in settings.evidence,
            settings.release,
        )
    }

    /** Moves pending JavaScript failures into the normal durable report queue. */
    @JvmStatic
    fun recover(context: Context): Boolean {
        val settings = Crumb.javaScriptCrashSettings() ?: return false
        return CrumbJavaScriptCrashRecovery.recover(context.applicationContext, settings)
    }
}
