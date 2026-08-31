package dev.crumb.distributionconsumer

import android.app.Activity
import android.os.Bundle
import android.widget.Button
import dev.crumb.core.Crumb
import dev.crumb.core.CrumbConfiguration
import dev.crumb.core.CrumbRelease
import dev.crumb.core.CrumbSDKVersion
import dev.crumb.ui.CrumbReporter

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        Crumb.start(
            CrumbConfiguration(
                projectKey = "distribution_rehearsal",
                environment = "test",
                release = CrumbRelease(appVersion = "1.0", nativeBuild = "1"),
            ),
        )
        CrumbReporter.install(application)

        setContentView(
            Button(this).apply {
                text = "Open Crumb ${CrumbSDKVersion.CURRENT}"
                setOnClickListener { CrumbReporter.show(this@MainActivity) }
            },
        )
    }
}
