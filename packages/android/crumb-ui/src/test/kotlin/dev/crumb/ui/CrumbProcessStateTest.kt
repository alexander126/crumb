package dev.crumb.ui

import android.app.ActivityManager.RunningAppProcessInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CrumbProcessStateTest {
    @Test
    fun foregroundUiImportanceCountsAsForeground() {
        assertTrue(
            CrumbProcessState.isForegroundImportance(
                RunningAppProcessInfo.IMPORTANCE_FOREGROUND,
            ),
        )
    }

    /** Delivery stays tied to the app being in front of the user. */
    @Test
    fun otherImportancesDoNotCountAsForeground() {
        listOf(
            RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE,
            RunningAppProcessInfo.IMPORTANCE_VISIBLE,
            RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE,
            RunningAppProcessInfo.IMPORTANCE_SERVICE,
            RunningAppProcessInfo.IMPORTANCE_BACKGROUND,
            RunningAppProcessInfo.IMPORTANCE_CACHED,
            RunningAppProcessInfo.IMPORTANCE_GONE,
        ).forEach { importance ->
            assertFalse(
                "importance $importance must not count as foreground",
                CrumbProcessState.isForegroundImportance(importance),
            )
        }
    }

    /** An unset importance is not evidence of a foreground process. */
    @Test
    fun anUnsetImportanceDoesNotCountAsForeground() {
        assertFalse(CrumbProcessState.isForegroundImportance(0))
    }
}
