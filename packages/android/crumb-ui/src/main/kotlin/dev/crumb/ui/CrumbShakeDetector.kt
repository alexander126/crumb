package dev.crumb.ui

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import kotlin.math.sqrt

internal class CrumbShakeDetector(
    context: Context,
    private val thresholdG: Float = 2.2f,
    private val onShake: () -> Unit,
) : SensorEventListener {
    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val gravity = FloatArray(3)
    private val recognizer = CrumbShakeGestureRecognizer(thresholdG = thresholdG)
    private var started = false

    fun start() {
        if (started || accelerometer == null) return
        started = sensorManager.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_GAME)
    }

    fun stop() {
        if (!started) return
        sensorManager.unregisterListener(this)
        started = false
        gravity.fill(0f)
        recognizer.reset()
    }

    override fun onSensorChanged(event: SensorEvent) {
        val alpha = 0.8f
        var magnitudeSquared = 0f
        for (index in 0..2) {
            gravity[index] = alpha * gravity[index] + (1f - alpha) * event.values[index]
            val linear = event.values[index] - gravity[index]
            magnitudeSquared += linear * linear
        }

        val magnitudeG = sqrt(magnitudeSquared) / SensorManager.GRAVITY_EARTH
        if (recognizer.record(magnitudeG, SystemClock.elapsedRealtime())) {
            onShake()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}

internal class CrumbShakeGestureRecognizer(
    private val thresholdG: Float = 2.2f,
    private val requiredHits: Int = 2,
    private val hitWindowMillis: Long = 600,
    private val cooldownMillis: Long = 1_500,
) {
    private val hitTimes = ArrayDeque<Long>()
    private var lastTriggerAt: Long? = null

    fun record(magnitudeG: Float, timestampMillis: Long): Boolean {
        if (magnitudeG < thresholdG) return false
        hitTimes.addLast(timestampMillis)
        while (hitTimes.firstOrNull()?.let { timestampMillis - it > hitWindowMillis } == true) {
            hitTimes.removeFirst()
        }

        if (hitTimes.size < requiredHits) return false
        if (lastTriggerAt?.let { timestampMillis - it < cooldownMillis } == true) {
            hitTimes.clear()
            return false
        }

        lastTriggerAt = timestampMillis
        hitTimes.clear()
        return true
    }

    fun reset() {
        hitTimes.clear()
        lastTriggerAt = null
    }
}
