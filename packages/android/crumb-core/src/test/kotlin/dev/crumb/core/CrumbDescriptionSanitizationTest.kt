package dev.crumb.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CrumbDescriptionSanitizationTest {
    @Test
    fun redactsSerializedAndReopenedQueuedDescriptions() {
        val cases = listOf(
            Triple("Step one\n\npassword=synthetic-secret\nStep two", "Step one\n\npassword=[REDACTED]\nStep two", listOf("synthetic-secret")),
            Triple("password\n=\nsynthetic-multiline\nNext paragraph", "password\n=\n[REDACTED]\nNext paragraph", listOf("synthetic-multiline")),
            Triple("""{"credentials":{"password":"synthetic-json","apiKey":"synthetic-api"},"safe":true}""",
                """{"credentials":{"password":"[REDACTED]","apiKey":"[REDACTED]"},"safe":true}""", listOf("synthetic-json", "synthetic-api")),
            Triple("Authorization: Digest username=synthetic-user, response=synthetic-digest\nNext paragraph",
                "Authorization: [REDACTED]\nNext paragraph", listOf("synthetic-user", "synthetic-digest")),
            Triple("Cookie: session=synthetic-session; second=synthetic-cookie\nNext paragraph",
                "Cookie: [REDACTED]\nNext paragraph", listOf("synthetic-session", "synthetic-cookie")),
            Triple("Bearer synthetic-bearer\n\nNext paragraph", "Bearer [REDACTED]\n\nNext paragraph", listOf("synthetic-bearer")),
            Triple("Open https://synthetic-user:synthetic-pass@example.invalid/path?session=synthetic-query",
                "Open https://[REDACTED]@example.invalid/path?session=[REDACTED]", listOf("synthetic-user", "synthetic-pass", "synthetic-query")),
            Triple("Contact synthetic@example.invalid", "Contact [REDACTED_EMAIL]", listOf("synthetic@example.invalid")),
            Triple("Card 0000 1111 2222 3333", "Card [REDACTED_NUMBER]", listOf("0000 1111 2222 3333")),
        )
        for ((raw, expected, secrets) in cases) {
            val envelope = build(raw)
            val root = Files.createTempDirectory("crumb-description-").toFile()
            try {
                val owner = "a".repeat(64)
                CrumbReportQueue(root, owner).enqueue(envelope, emptyList())
                val persisted = File(File(root, envelope.reportId), "envelope.json").readBytes()
                val payload = CrumbReportQueue(root, owner).load(envelope.reportId)
                assertArrayEquals(envelope.json.toByteArray(Charsets.UTF_8), persisted)
                assertArrayEquals(persisted, payload.envelope)
                assertEquals(expected, description(payload.envelope.toString(Charsets.UTF_8)))
                assertEquals(expected, description(envelope.json))
                for (secret in secrets) {
                    assertFalse(envelope.json.contains(secret))
                    assertFalse(persisted.toString(Charsets.UTF_8).contains(secret))
                    assertFalse(payload.envelope.toString(Charsets.UTF_8).contains(secret))
                }
            } finally {
                root.deleteRecursively()
            }
        }
    }

    @Test
    fun preservesParagraphsTabsAndExistingMarkersAcrossRepeatedBuilds() {
        val raw = "  First café🙂\n\n\tSecond paragraph\nCookie: synthetic-cookie=secret-cookie\n\nThird  "
        val expected = "First café🙂\n\n\tSecond paragraph\nCookie: [REDACTED]\n\nThird"
        val sanitized = description(build(raw).json)
        assertEquals(expected, sanitized)
        assertEquals(expected, description(build(sanitized).json))
        assertEquals("token=[REDACTED]\n\nSafe paragraph", description(build("token=[REDACTED]\n\nSafe paragraph").json))
        assertEquals("one  two", CrumbFailureText.sanitize("one\n\ttwo"))
    }

    @Test
    fun validatesTheFinalBoundAfterRedactionExpansion() {
        val fitting = "a".repeat(3_983) + "\nx@y.co"
        val expected = "a".repeat(3_983) + "\n[REDACTED_EMAIL]"
        assertEquals(4_000, expected.length)
        assertEquals(expected, description(build(fitting).json))
        for (count in listOf(3_984, 3_993)) {
            assertThrows(CrumbReportEnvelopeException.InvalidDescription::class.java) {
                build("a".repeat(count) + "\nx@y.co")
            }
        }
    }

    @Test
    fun keepsRawLimitsAndRejectsEmptySanitizedOutput() {
        assertEquals(4_000, description(build("a".repeat(4_000)).json).length)
        for (raw in listOf("password=" + "s".repeat(3_992), "a".repeat(4_001), " \n\t", "\u0000")) {
            assertThrows(CrumbReportEnvelopeException.InvalidDescription::class.java) { build(raw) }
        }
    }

    private fun description(json: String) = JSONObject(json).getJSONObject("user_input").getString("description")

    private fun build(description: String): CrumbSerializedReportEnvelope {
        val settings = CrumbReportSettings(
            environment = "test", release = CrumbRelease("1", "1"),
            invocation = setOf(CrumbInvocation.PROGRAMMATIC), capture = CrumbCaptureOptions(screenshot = false),
            diagnostics = CrumbDiagnosticsOptions(), privacy = CrumbPrivacyOptions(),
            reporter = CrumbReporterOptions(), evidence = emptySet(), application = CrumbApplicationMetadata(),
            customContext = emptyMap(), policyStatus = CrumbPolicyStatus.NOT_CONFIGURED, workspacePolicyVersion = null,
        )
        val snapshot = CrumbDiagnosticsSnapshot(
            capturedAtMillis = 1_700_000_000_000, location = "SyntheticScreen", processName = "SyntheticApp", processId = 1,
            cpuUsagePercent = null, residentMemoryBytes = null, physicalFootprintBytes = null,
            thermalState = "unknown", threadCount = 0, busiestThreads = emptyList(), gpuStatus = "unavailable",
            network = CrumbNetworkDiagnostic("unknown", "unknown", null, false, false, null),
            logs = CrumbLogDiagnostic(CrumbLogCaptureStatus.EMPTY, emptyList(), emptyList(), false, 0, emptyList()),
            stackTraces = CrumbStackTraceDiagnostic(CrumbStackTraceCaptureStatus.UNAVAILABLE, "unavailable", emptyList(), false, "not_available"),
        )
        return CrumbReportEnvelopeBuilder.build(settings, CrumbReportBuildInput(
            reportId = "rpt_0123456789abcdef0123456789abcdef", trigger = CrumbInvocation.PROGRAMMATIC,
            triggeredAtMillis = 1_700_000_000_000, submittedAtMillis = 1_700_000_000_000,
            runtime = CrumbReportRuntime("17", "synthetic", "en", "UTC"), category = "bug", description = description,
            diagnostics = snapshot, screenshotCapture = CrumbScreenshotCaptureState.DISABLED_BY_CONFIGURATION,
            screenshotMasking = CrumbScreenshotMaskingState.NOT_APPLICABLE,
        ))
    }
}
