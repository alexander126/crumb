package dev.crumb.demo

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbLogEntry
import dev.crumb.core.CrumbLogLevel
import dev.crumb.core.CrumbLogProvider
import dev.crumb.ui.CrumbReporter

class MainActivity : Activity() {
    private lateinit var activityLabel: TextView
    @Volatile private var cpuPressureRunning = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DemoLogBuffer.append(CrumbLogLevel.NOTICE, "Demo activity created")

        val demoConfiguration = DemoCrumbConfiguration.make(logProvider = DemoLogBuffer)
        Crumb.start(demoConfiguration.crumb)
        CrumbReporter.install(application)
        setContentView(buildInterface(demoConfiguration.modeDescription))
    }

    private fun buildInterface(modeDescription: String): ScrollView {
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(72), dp(24), dp(32))
        }

        content.addView(text("Crumb native demo", 30f, Color.rgb(22, 24, 28)))
        content.addView(text(
            modeDescription,
            13f,
            if (modeDescription == "Staging upload enabled") Color.rgb(22, 125, 78) else Color.DKGRAY,
        ).apply { tag = "demo.delivery-mode" }.margin(top = 8))
        content.addView(text("Checkout preview", 22f, Color.rgb(22, 24, 28)).margin(top = 28))
        content.addView(text(
            "Crumb stays idle until you report a problem. The card field below must be hidden in the captured screenshot.",
            16f,
            Color.DKGRAY,
        ).margin(top = 12, bottom = 20))

        val cardField = EditText(this).apply {
            setText("4242 4242 4242 4242")
            hint = "Card number"
            inputType = InputType.TYPE_CLASS_NUMBER
            contentDescription = "Sensitive card number"
            tag = "demo.sensitive-card"
        }
        content.addView(cardField, matchWrap().margin(bottom = 18))

        activityLabel = text("No simulated problem running", 14f, Color.DKGRAY).apply {
            tag = "demo.activity-count"
        }
        content.addView(activityLabel, matchWrap().margin(bottom = 14))

        content.addView(Button(this).apply {
            text = "Simulate CPU pressure"
            tag = "demo.simulate-activity"
            setOnClickListener { simulateActivity() }
        }, matchWrap().margin(bottom = 12))

        content.addView(Button(this).apply {
            text = "Report a problem"
            tag = "demo.report-problem"
            setOnClickListener {
                DemoLogBuffer.append(CrumbLogLevel.NOTICE, "Problem reporter invoked by button")
                CrumbReporter.show(this@MainActivity)
            }
            setOnLongClickListener {
                DemoLogBuffer.append(CrumbLogLevel.NOTICE, "Problem reporter invoked by simulated shake")
                CrumbReporter.show(this@MainActivity, dev.crumb.core.CrumbInvocation.SHAKE)
                true
            }
        }, matchWrap().margin(bottom = 10))

        content.addView(text("Crumb owns shake detection and only enables it while the app is foregrounded.", 12f, Color.GRAY))
        return ScrollView(this).apply { addView(content) }
    }

    private fun simulateActivity() {
        if (cpuPressureRunning) return
        DemoLogBuffer.append(CrumbLogLevel.WARNING, "Demo CPU pressure started")
        cpuPressureRunning = true
        activityLabel.text = "CPU pressure active for 4 seconds"
        Thread({
            val deadline = System.nanoTime() + 4_000_000_000
            var accumulator = 0.0
            while (System.nanoTime() < deadline) accumulator += kotlin.math.sqrt(Math.random())
            accumulator.hashCode()
            runOnUiThread {
                cpuPressureRunning = false
                activityLabel.text = "CPU pressure finished"
                DemoLogBuffer.append(CrumbLogLevel.NOTICE, "Demo CPU pressure finished")
            }
        }, "Demo CPU pressure").start()
    }

    internal fun measureWarmStarts(runCount: Int): List<Double> {
        val configuration = DemoCrumbConfiguration.make(logProvider = DemoLogBuffer).crumb
        return List(runCount) {
            val startedAt = android.os.SystemClock.elapsedRealtimeNanos()
            Crumb.start(configuration)
            (android.os.SystemClock.elapsedRealtimeNanos() - startedAt) / 1_000_000.0
        }
    }

    private fun text(value: String, size: Float, color: Int) = TextView(this).apply {
        text = value
        textSize = size
        setTextColor(color)
    }

    private fun matchWrap() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    private fun <T : android.view.View> T.margin(top: Int = 0, bottom: Int = 0): T {
        layoutParams = matchWrap().margin(top, bottom)
        return this
    }

    private fun LinearLayout.LayoutParams.margin(top: Int = 0, bottom: Int = 0) = apply {
        topMargin = dp(top)
        bottomMargin = dp(bottom)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}

internal object DemoLogBuffer : CrumbLogProvider {
    private val entries = ArrayDeque<CrumbLogEntry>()

    fun append(level: CrumbLogLevel, message: String) = synchronized(entries) {
        entries.addLast(
            CrumbLogEntry(
                timestampMillis = System.currentTimeMillis(),
                level = level,
                source = "demo",
                category = "checkout",
                message = message,
            ),
        )
        while (entries.size > 100) entries.removeFirst()
    }

    override fun recentLogs(): List<CrumbLogEntry> = synchronized(entries) {
        entries.toList()
    }
}
