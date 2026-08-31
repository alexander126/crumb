package dev.crumb.ui

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbReportQueue
import dev.crumb.core.CrumbReportUploadWorker
import dev.crumb.core.CrumbUploadPassResult

internal object CrumbUploadCoordinator {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val retryDelaysMillis = longArrayOf(1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000)

    private var application: Application? = null
    private var worker: CrumbReportUploadWorker? = null
    private var running = false
    private var foreground = false
    private var retryStep = 0
    private var retryRunnable: Runnable? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    fun install(application: Application) {
        if (this.application != null) return
        val settings = runCatching { Crumb.uploadSettings() }.getOrNull() ?: return
        this.application = application
        worker = CrumbReportUploadWorker.create(CrumbReportQueue.from(application), settings)
    }

    fun resume(application: Application) {
        install(application)
        foreground = true
        wake()
    }

    fun pause() {
        foreground = false
        retryRunnable?.let(mainHandler::removeCallbacks)
        retryRunnable = null
        worker?.cancel()
        stopConnectivityMonitoring()
    }

    fun reportDidQueue() {
        wake()
    }

    private fun wake() {
        val activeWorker = worker ?: return
        if (!foreground || running) return
        startConnectivityMonitoring()
        retryRunnable?.let(mainHandler::removeCallbacks)
        retryRunnable = null
        running = true
        activeWorker.prepareForPass()
        Thread({
            val result = activeWorker.runPass()
            mainHandler.post {
                running = false
                handle(result)
            }
        }, "Crumb report upload").start()
    }

    private fun handle(result: CrumbUploadPassResult) {
        if (result.remainingReportCount == 0) {
            retryStep = 0
            stopConnectivityMonitoring()
            return
        }
        if (!foreground) return
        when {
            result.wasCancelled -> wake()
            result.shouldRetry -> scheduleRetry()
            else -> stopConnectivityMonitoring()
        }
    }

    private fun scheduleRetry() {
        val delay = retryDelaysMillis[retryStep.coerceAtMost(retryDelaysMillis.lastIndex)]
        retryStep = (retryStep + 1).coerceAtMost(retryDelaysMillis.lastIndex)
        retryRunnable?.let(mainHandler::removeCallbacks)
        val runnable = Runnable {
            retryRunnable = null
            wake()
        }
        retryRunnable = runnable
        mainHandler.postDelayed(runnable, delay)
    }

    private fun startConnectivityMonitoring() {
        if (networkCallback != null) return
        val app = application ?: return
        val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post {
                    if (!foreground) return@post
                    retryStep = 0
                    retryRunnable?.let(mainHandler::removeCallbacks)
                    retryRunnable = null
                    wake()
                }
            }
        }
        try {
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (_: SecurityException) {
            // Timed retry remains available if a host manifest strips the merged permission.
        } catch (_: RuntimeException) {
            // Local submission and durable retry do not depend on connectivity observation.
        }
    }

    private fun stopConnectivityMonitoring() {
        val callback = networkCallback ?: return
        val app = application
        val manager = app?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        runCatching { manager?.unregisterNetworkCallback(callback) }
        networkCallback = null
    }
}
