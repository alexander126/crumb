package dev.crumb.ui

import dev.crumb.core.CrumbReportQueue
import dev.crumb.core.CrumbReportQueueException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Lives in crumb-ui because crumb-core's unit tests are deliberately plain JVM
 * with no Robolectric environment. The rules themselves are unit-tested in
 * crumb-core by CrumbProcessIdentityTest.
 */
@RunWith(RobolectricTestRunner::class)
class CrumbQueueProcessBoundaryTest {
    @Test
    fun theQueueIsAvailableInTheMainProcess() {
        assertNotNull(CrumbReportQueue.from(RuntimeEnvironment.getApplication()))
    }

    /**
     * The process name is passed explicitly because this runtime cannot name
     * its own process: Application.getProcessName is not populated under
     * Robolectric and there is no /proc on macOS. On a device the default is
     * the real name.
     */
    @Test
    fun theQueueRefusesAPrivateSecondaryProcess() {
        val application = RuntimeEnvironment.getApplication()

        assertThrows(CrumbReportQueueException.UnsupportedProcess::class.java) {
            CrumbReportQueue.from(application, "${application.packageName}:remote")
        }
    }

    /** A global secondary process, declared as android:process=".remote". */
    @Test
    fun theQueueRefusesAGlobalSecondaryProcess() {
        val application = RuntimeEnvironment.getApplication()

        assertThrows(CrumbReportQueueException.UnsupportedProcess::class.java) {
            CrumbReportQueue.from(application, "${application.packageName}.remote")
        }
    }

    @Test
    fun theQueueAcceptsTheMainProcessName() {
        val application = RuntimeEnvironment.getApplication()

        assertNotNull(CrumbReportQueue.from(application, application.packageName))
    }

    /**
     * The reporter writes to the queue, so it applies the same rule. Both sides
     * take the process name as a parameter because this runtime cannot name its
     * own process: /proc does not exist on macOS and Robolectric does not
     * populate Application.getProcessName.
     */
    @Test
    fun theReporterSharesTheSameProcessRule() {
        val application = RuntimeEnvironment.getApplication()
        val packageName = application.packageName

        assertTrue(CrumbProcessState.isMainProcess(application, packageName))
        assertFalse(CrumbProcessState.isMainProcess(application, "$packageName:remote"))
        assertFalse(CrumbProcessState.isMainProcess(application, "$packageName.remote"))
        assertFalse(CrumbProcessState.isMainProcess(application, "com.example.other"))
        // An unnamable process must not break a working single-process host.
        assertTrue(CrumbProcessState.isMainProcess(application, null))
    }
}
