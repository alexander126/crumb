package dev.crumb.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.json.JSONObject
import java.util.UUID

class CrumbTest {
    @Before
    fun setUp() = Crumb.resetForTesting()

    @After
    fun tearDown() = Crumb.resetForTesting()

    @Test
    fun defaultsArePrivateAndOnDemand() {
        assertTrue(CrumbPrivacyOptions().maskAllTextInputs)
        assertTrue(CrumbPrivacyOptions().maskScreenshotsBeforeUpload)
        assertTrue(CrumbCaptureOptions().screenshot)
        assertEquals(2_048, CrumbCaptureOptions().maximumScreenshotDimension)
        assertEquals(5_242_880, CrumbCaptureOptions().maximumScreenshotBytes)
        assertNull(CrumbDiagnosticsOptions().healthCheckUrl)
        assertEquals(2_000, CrumbDiagnosticsOptions().timeoutMillis)
        assertTrue(CrumbDiagnosticsOptions().logs.enabled)
        assertEquals(60_000, CrumbDiagnosticsOptions().logs.lookbackMillis)
        assertEquals(200, CrumbDiagnosticsOptions().logs.maximumEntries)
        assertEquals(65_536, CrumbDiagnosticsOptions().logs.maximumBytes)
        assertNull(CrumbDiagnosticsOptions().logs.provider)
        assertNull(CrumbUploadOptions().ingestionUrl)
    }

    @Test
    fun rejectsOversizedOrHeaderUnsafeConfigurationMetadata() {
        val invalidConfigurations = listOf(
            configuration(projectKey = "k".repeat(513)),
            configuration(projectKey = "key\r\nInjected: value"),
            configuration(environment = "e".repeat(65)),
            configuration(environment = "test\u0000"),
            configuration(release = CrumbRelease("v".repeat(65), "1")),
            configuration(release = CrumbRelease("1.0", "b".repeat(65))),
            configuration(release = CrumbRelease("1.0", "1", "j".repeat(129))),
        )

        invalidConfigurations.forEach { candidate ->
            Crumb.resetForTesting()
            try {
                Crumb.start(candidate)
                throw AssertionError("Expected configuration metadata rejection")
            } catch (_: CrumbStartException.InvalidProjectKey) {
                // Expected for project-key cases.
            } catch (_: CrumbStartException.InvalidEnvironment) {
                // Expected for environment cases.
            } catch (_: CrumbStartException.InvalidRelease) {
                // Expected for release cases.
            }
        }
    }

    @Test(expected = CrumbStartException.InvalidScreenshotDimension::class)
    fun rejectsInvalidScreenshotDimension() {
        Crumb.start(configuration(capture = CrumbCaptureOptions(maximumScreenshotDimension = 319)))
    }

    @Test(expected = CrumbStartException.InvalidScreenshotByteLimit::class)
    fun rejectsInvalidScreenshotByteLimit() {
        Crumb.start(configuration(capture = CrumbCaptureOptions(maximumScreenshotBytes = 65_535)))
    }

    @Test(expected = CrumbStartException.InvalidDiagnosticsTimeout::class)
    fun rejectsInvalidDiagnosticsTimeout() {
        Crumb.start(configuration(diagnostics = CrumbDiagnosticsOptions(timeoutMillis = 100)))
    }

    @Test(expected = CrumbStartException.InvalidHealthCheckUrl::class)
    fun rejectsInvalidHealthCheckUrl() {
        Crumb.start(
            configuration(
                diagnostics = CrumbDiagnosticsOptions(
                    healthCheckUrl = "https://ingestion.crumb.dev/health?token=value",
                ),
            ),
        )
    }

    @Test
    fun acceptsRepeatedEquivalentStart() {
        val configuration = configuration()
        Crumb.start(configuration)
        Crumb.start(configuration)
    }

    @Test(expected = CrumbStartException.InvalidLogLimits::class)
    fun rejectsInvalidLogLimits() {
        Crumb.start(
            configuration(
                diagnostics = CrumbDiagnosticsOptions(
                    logs = CrumbLogOptions(maximumEntries = 0),
                ),
            ),
        )
    }

    @Test
    fun validatesAndIsolatesUploadConfiguration() {
        Crumb.start(configuration(upload = CrumbUploadOptions("https://ingestion.crumb.dev")))
        val settings = checkNotNull(Crumb.uploadSettings())
        assertEquals("project_write_key", settings.projectKey)
        assertEquals("https://ingestion.crumb.dev", settings.ingestionUrl)

        Crumb.resetForTesting()
        try {
            Crumb.start(configuration(upload = CrumbUploadOptions("ftp://ingestion.crumb.dev")))
            throw AssertionError("Expected invalid ingestion URL")
        } catch (_: CrumbStartException.InvalidIngestionUrl) {
            // Expected.
        }
    }

    @Test
    fun exposesOnlyReportTimeSettingsToTheUi() {
        Crumb.start(
            configuration(
                invocation = setOf(CrumbInvocation.PROGRAMMATIC),
                capture = CrumbCaptureOptions(screenshot = false),
                diagnostics = CrumbDiagnosticsOptions(
                    healthCheckUrl = "https://health.crumb.dev/ping",
                    timeoutMillis = 1_250,
                ),
                privacy = CrumbPrivacyOptions(maskAllTextInputs = false),
            ),
        )

        val settings = Crumb.reportSettings()

        assertFalse(settings.capture.screenshot)
        assertEquals("https://health.crumb.dev/ping", settings.diagnostics.healthCheckUrl)
        assertEquals(1_250, settings.diagnostics.timeoutMillis)
        assertFalse(settings.privacy.maskAllTextInputs)
        assertEquals(setOf(CrumbInvocation.PROGRAMMATIC), settings.invocation)
    }

    @Test
    fun buildsContractReadyReportEnvelope() {
        Crumb.start(configuration())

        val envelope = Crumb.buildReport(reportInput())

        assertEquals("rpt_0123456789abcdef0123456789abcdef", envelope.reportId)
        assertTrue(envelope.json.contains("\"schema_version\":\"1.0\""))
        assertTrue(envelope.json.contains("\"report_id\":\"${envelope.reportId}\""))
        assertTrue(envelope.json.contains("\"trigger\":\"shake\""))
        assertTrue(envelope.json.contains("\"platform\":\"android\""))
        assertTrue(envelope.json.contains("\"name\":\"crumb-android\""))
        assertTrue(envelope.json.contains("\"version\":\"${CrumbSDKVersion.CURRENT}\""))
        assertTrue(envelope.json.contains("\"cellular_generation\":\"4g_lte\""))
        assertTrue(envelope.json.contains("\"latency_ms\":42"))
        assertTrue(envelope.json.contains("\"diagnostics_capture\":\"on_demand\""))
        assertTrue(envelope.json.contains("\"log_capture\":\"enabled\""))
        assertTrue(envelope.json.contains("\"stack_traces\":"))
        assertTrue(envelope.json.contains("\"upload_id\":\"upl_0123456789AB\""))
        assertFalse(envelope.json.contains("reportId"))
    }

    @Test
    fun preservesDeviceConnectivityWhenTheCrumbApiIsUnavailable() {
        Crumb.start(configuration())

        val envelope = Crumb.buildReport(reportInput(healthCheckSucceeded = false))
        val network = JSONObject(envelope.json)
            .getJSONObject("diagnostics")
            .getJSONObject("network")
        val health = network.getJSONObject("health_check")

        assertEquals("reachable", network.getString("status"))
        assertFalse(health.getBoolean("succeeded"))
        assertFalse(health.has("status_code"))
        assertEquals("timeout", health.getString("failure"))
    }

    @Test(expected = CrumbReportEnvelopeException.InvalidTimestampOrder::class)
    fun rejectsReportWithReversedTimestamps() {
        Crumb.start(configuration())
        Crumb.buildReport(
            reportInput(
                triggeredAtMillis = 1_700_000_002_000,
                submittedAtMillis = 1_700_000_000_000,
            ),
        )
    }

    @Test(expected = CrumbReportEnvelopeException.InvalidArtifact::class)
    fun rejectsReportWithInvalidArtifactManifest() {
        Crumb.start(configuration())
        Crumb.buildReport(reportInput(artifactKind = "video"))
    }

    private fun reportInput(
        triggeredAtMillis: Long = 1_700_000_000_000,
        submittedAtMillis: Long = 1_700_000_002_000,
        artifactKind: String = "screenshot",
        healthCheckSucceeded: Boolean = true,
    ) = CrumbReportBuildInput(
        reportId = CrumbReportEnvelopeBuilder.makeReportId(
            UUID.fromString("01234567-89ab-cdef-0123-456789abcdef"),
        ),
        trigger = CrumbInvocation.SHAKE,
        triggeredAtMillis = triggeredAtMillis,
        submittedAtMillis = submittedAtMillis,
        runtime = CrumbReportRuntime(
            osVersion = "16",
            deviceFamily = "Pixel",
            locale = "en-US",
            timezone = "Europe/Athens",
        ),
        category = "Bug",
        description = "Checkout froze after tapping Pay",
        diagnostics = diagnostics(triggeredAtMillis + 1_000, healthCheckSucceeded),
        screenshotCapture = CrumbScreenshotCaptureState.ENABLED,
        screenshotMasking = CrumbScreenshotMaskingState.APPLIED,
        artifacts = listOf(
            CrumbArtifactManifest(
                id = "art_0123456789AB",
                kind = artifactKind,
                mimeType = "image/png",
                byteSize = 128,
                sha256 = "a".repeat(64),
                redactionState = "masked",
                uploadId = "upl_0123456789AB",
            ),
        ),
    )

    private fun diagnostics(
        capturedAtMillis: Long,
        healthCheckSucceeded: Boolean,
    ) = CrumbDiagnosticsSnapshot(
        capturedAtMillis = capturedAtMillis,
        location = "CheckoutActivity",
        processName = "CrumbDemo",
        processId = 42,
        cpuUsagePercent = 17.5,
        residentMemoryBytes = 50_000_000,
        physicalFootprintBytes = 70_000_000,
        thermalState = "nominal",
        threadCount = 4,
        busiestThreads = listOf(
            CrumbThreadDiagnostic(id = 7, name = "main", state = "running", cpuUsagePercent = 12.5),
        ),
        gpuStatus = "unavailable_on_demand",
        network = CrumbNetworkDiagnostic(
            status = "reachable",
            transport = "cellular",
            cellularGeneration = "4G/LTE",
            isExpensive = true,
            isConstrained = false,
            healthCheck = CrumbHealthCheckDiagnostic(
                host = "api.crumb.dev",
                succeeded = healthCheckSucceeded,
                statusCode = if (healthCheckSucceeded) 204 else null,
                latencyMilliseconds = if (healthCheckSucceeded) 42 else 1_250,
                failure = if (healthCheckSucceeded) null else "timeout",
            ),
        ),
        logs = CrumbLogDiagnostic(
            status = CrumbLogCaptureStatus.CAPTURED,
            sources = listOf("application"),
            entries = listOf(
                CrumbLogEntry(
                    timestampMillis = capturedAtMillis,
                    level = CrumbLogLevel.ERROR,
                    category = "checkout",
                    message = "Payment request timed out",
                ),
            ),
            truncated = false,
            droppedEntryCount = 0,
            failures = emptyList(),
        ),
        stackTraces = CrumbStackTraceDiagnostic(
            status = CrumbStackTraceCaptureStatus.CAPTURED,
            scope = "managed_threads",
            threads = listOf(
                CrumbThreadStackDiagnostic(
                    id = 7,
                    name = "main",
                    state = "running",
                    frames = listOf("CheckoutActivity.pay()"),
                ),
            ),
            truncated = false,
            unavailableReason = null,
        ),
    )

    private fun configuration(
        projectKey: String = "project_write_key",
        environment: String = "test",
        release: CrumbRelease = CrumbRelease(appVersion = "1.0.0", nativeBuild = "1"),
        invocation: Set<CrumbInvocation> = setOf(CrumbInvocation.SHAKE, CrumbInvocation.PROGRAMMATIC),
        capture: CrumbCaptureOptions = CrumbCaptureOptions(),
        diagnostics: CrumbDiagnosticsOptions = CrumbDiagnosticsOptions(),
        privacy: CrumbPrivacyOptions = CrumbPrivacyOptions(),
        upload: CrumbUploadOptions = CrumbUploadOptions(),
    ) = CrumbConfiguration(
        projectKey = projectKey,
        environment = environment,
        release = release,
        invocation = invocation,
        capture = capture,
        diagnostics = diagnostics,
        privacy = privacy,
        upload = upload,
    )
}
