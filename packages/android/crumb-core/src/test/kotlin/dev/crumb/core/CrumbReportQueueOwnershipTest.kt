package dev.crumb.core

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Properties
import java.security.MessageDigest

class CrumbReportQueueOwnershipTest {
    private val originalKey = "synthetic-original-key"
    private val originalDestination = "https://original.example.test/base"

    @Test
    fun legacyUnknownReportIsNotSentWithReplacementSettings() {
        val root = Files.createTempDirectory("crumb-owner-legacy").toFile()
        try {
            val queue = CrumbReportQueue(root)
            val reportId = "rpt_LegacyAAAAAAAAAAAAAAAAAAAAAAAAAA"
            queue.enqueue(envelope(reportId), emptyList())
            queue.markUploading(reportId)
            val metadata = File(File(root, reportId), "record.properties")
            val properties = Properties().apply { metadata.inputStream().use(::load) }
            properties.setProperty("schema_version", "1")
            properties.remove("owner_fingerprint")
            metadata.outputStream().use { properties.store(it, null) }
            val before = snapshot(root)
            val transport = AcceptingTransport()
            val worker = CrumbReportUploadWorker(
                queue,
                CrumbUploadSettings("synthetic-replacement-key", "https://replacement.example.test"),
                transport,
            )

            val result = worker.runPass()

            assertEquals("unknown reports must not reach the replacement project", 0, transport.requests.size)
            assertEquals(0, result.remainingReportCount)
            assertFalse(result.shouldRetry)
            assertEquals(CrumbQueuedReportState.UPLOADING, queue.reports().single().state)
            assertEquals(1, queue.reports().single().attemptCount)
            assertSnapshotEquals(before, snapshot(root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun matchingOwnerSurvivesRestartAndUploadsArtifactThroughTheNormalLifecycle() {
        val root = Files.createTempDirectory("crumb-owner-matching").toFile()
        try {
            val owner = CrumbQueueOwner.from(originalKey, originalDestination)
            val fixture = fixture("rpt_MatchingAAAAAAAAAAAAAAAAAAAAAAAA")
            CrumbReportQueue(root, owner).apply {
                enqueue(fixture.envelope, fixture.artifacts)
                markUploading(fixture.envelope.reportId)
                assertEquals(owner.fingerprint, metadata(root, fixture.envelope.reportId).getProperty("owner_fingerprint"))
            }
            val restarted = CrumbReportQueue(root, owner)
            val transport = AcceptingTransport()

            val result = CrumbReportUploadWorker(
                restarted,
                CrumbUploadSettings(originalKey, originalDestination),
                transport,
            ).runPass()

            assertEquals(1, result.uploadedReportCount)
            assertEquals(0, result.remainingReportCount)
            assertFalse(result.shouldRetry)
            assertEquals(listOf("POST", "PUT", "POST"), transport.requests.map { it.method })
            assertTrue(restarted.reports().isEmpty())
            assertArrayEquals(fixture.artifacts.single().bytes, transport.requests[1].body)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun foreignKeyOrDestinationDoesNotChangeAnyQueuedBytesOrStates() {
        val root = Files.createTempDirectory("crumb-owner-foreign").toFile()
        try {
            val owner = CrumbQueueOwner.from(originalKey, originalDestination)
            val queue = CrumbReportQueue(root, owner)
            val uploading = fixture("rpt_ForeignUploadingAAAAAAAAAAAAAAAA")
            val failed = fixture("rpt_ForeignFailedAAAAAAAAAAAAAAAAAAA")
            queue.enqueue(uploading.envelope, uploading.artifacts)
            queue.enqueue(failed.envelope, failed.artifacts)
            queue.markUploading(uploading.envelope.reportId)
            queue.markUploading(failed.envelope.reportId)
            queue.markFailed(failed.envelope.reportId, "synthetic.previous_failure")
            val before = snapshot(root)
            val summaries = queue.reports()
            val replacements = listOf(
                CrumbUploadSettings("synthetic-rotated-key", originalDestination),
                CrumbUploadSettings(originalKey, "https://replacement.example.test/base"),
                CrumbUploadSettings(originalKey, "https://original.example.test/other"),
                CrumbUploadSettings(originalKey, "https://original.example.test:8443/base"),
            )

            replacements.forEach { settings ->
                val restarted = CrumbReportQueue(root, CrumbQueueOwner.from(settings.projectKey, settings.ingestionUrl))
                restarted.recoverInterruptedUploads()
                val transport = AcceptingTransport()
                val result = CrumbReportUploadWorker(restarted, settings, transport).runPass()

                assertTrue(transport.requests.isEmpty())
                assertEquals(0, result.remainingReportCount)
                assertFalse(result.shouldRetry)
                assertEquals(summaries, restarted.reports())
                assertSnapshotEquals(before, snapshot(root))
                assertArrayEquals(uploading.artifacts.single().bytes, restarted.load(uploading.envelope.reportId).artifacts.single().bytes)
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun enablingUploadDoesNotAdoptAnItemCommittedInLocalOnlyMode() {
        val root = Files.createTempDirectory("crumb-owner-local").toFile()
        try {
            val fixture = fixture("rpt_LocalOnlyAAAAAAAAAAAAAAAAAAAAAAA")
            val local = CrumbReportQueue(root, CrumbQueueOwner.from(originalKey, null))
            local.enqueue(fixture.envelope, fixture.artifacts)
            val before = snapshot(root)
            val transport = AcceptingTransport()

            val result = CrumbReportUploadWorker(
                local,
                CrumbUploadSettings(originalKey, originalDestination),
                transport,
            ).runPass()

            assertTrue(transport.requests.isEmpty())
            assertEquals(0, result.remainingReportCount)
            assertFalse(result.shouldRetry)
            assertSnapshotEquals(before, snapshot(root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun metadataContainsOnlyTheFingerprintAndOwnerChangesCannotReuseAReportId() {
        val root = Files.createTempDirectory("crumb-owner-metadata").toFile()
        try {
            val owner = CrumbQueueOwner.from(originalKey, originalDestination)
            val original = CrumbReportQueue(root, owner)
            val fixture = fixture("rpt_IdempotentAAAAAAAAAAAAAAAAAAAAAA")
            val first = original.enqueue(fixture.envelope, fixture.artifacts)
            val before = snapshot(root)
            val restarted = CrumbReportQueue(root, owner)
            assertEquals(first, restarted.enqueue(fixture.envelope, fixture.artifacts))
            val stored = metadata(root, fixture.envelope.reportId)
            assertEquals("2", stored.getProperty("schema_version"))
            assertEquals(owner.fingerprint, stored.getProperty("owner_fingerprint"))
            val metadataText = File(File(root, fixture.envelope.reportId), "record.properties").readText()
            assertFalse(metadataText.contains(originalKey))
            assertFalse(metadataText.contains("original.example.test"))
            assertFalse(fixture.envelope.json.contains(originalKey))
            assertFalse(fixture.envelope.json.contains("original.example.test"))
            val foreign = CrumbReportQueue(root, CrumbQueueOwner.from("synthetic-rotated-key", originalDestination))

            assertThrows(CrumbReportQueueException.ConflictingReport::class.java) {
                foreign.enqueue(fixture.envelope, fixture.artifacts)
            }
            assertSnapshotEquals(before, snapshot(root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun foreignReportsContinueCountingAgainstGlobalQueueBudgets() {
        val root = Files.createTempDirectory("crumb-owner-budget").toFile()
        try {
            val limits = CrumbQueueLimits(maximumReports = 1)
            val original = CrumbReportQueue(root, CrumbQueueOwner.from(originalKey, originalDestination), limits)
            val existing = fixture("rpt_BudgetExistingAAAAAAAAAAAAAAAAAA")
            original.enqueue(existing.envelope, existing.artifacts)
            val before = snapshot(root)
            val replacement = CrumbReportQueue(
                root,
                CrumbQueueOwner.from("synthetic-rotated-key", originalDestination),
                limits,
            )
            val next = fixture("rpt_BudgetNewAAAAAAAAAAAAAAAAAAAAAAA")

            assertThrows(CrumbReportQueueException.QueueFull::class.java) {
                replacement.enqueue(next.envelope, next.artifacts)
            }
            assertSnapshotEquals(before, snapshot(root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun legacyVersionIgnoresAnUnexpectedOwnerFieldAndUnknownVersionTwoStaysLocal() {
        val root = Files.createTempDirectory("crumb-owner-unknown").toFile()
        try {
            val queue = CrumbReportQueue(root)
            val legacyId = "rpt_LegacyFieldAAAAAAAAAAAAAAAAAAAAA"
            val unknownId = "rpt_UnknownOwnerAAAAAAAAAAAAAAAAAAAA"
            queue.enqueue(envelope(legacyId), emptyList())
            queue.enqueue(envelope(unknownId), emptyList())
            val stored = metadata(root, legacyId)
            stored.setProperty("schema_version", "1")
            stored.setProperty("owner_fingerprint", CrumbQueueOwner.from(originalKey, originalDestination).fingerprint)
            File(File(root, legacyId), "record.properties").outputStream().use { stored.store(it, null) }
            val before = snapshot(root)
            val transport = AcceptingTransport()

            val result = CrumbReportUploadWorker(
                queue,
                CrumbUploadSettings(originalKey, originalDestination),
                transport,
            ).runPass()

            assertTrue(transport.requests.isEmpty())
            assertEquals(0, result.remainingReportCount)
            assertFalse(result.shouldRetry)
            assertEquals(2, queue.reports().size)
            assertSnapshotEquals(before, snapshot(root))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun fingerprintsNormalizeOnlyEquivalentDestinationComponents() {
        val owner = CrumbQueueOwner.from(originalKey, originalDestination)
        assertEquals(owner, CrumbQueueOwner.from(originalKey, "HTTPS://ORIGINAL.EXAMPLE.TEST:443/base///"))
        assertEquals(
            CrumbQueueOwner.from(originalKey, "https://original.example.test"),
            CrumbQueueOwner.from(originalKey, "https://original.example.test:443///"),
        )
        assertNotEquals(owner, CrumbQueueOwner.from("synthetic-rotated-key", originalDestination))
        assertNotEquals(owner, CrumbQueueOwner.from(originalKey, "https://original.example.test/Base"))
        assertNotEquals(owner, CrumbQueueOwner.from(originalKey, null))
        assertNotEquals(
            CrumbQueueOwner.from(originalKey, "https://original.example.test/a%2Fb"),
            CrumbQueueOwner.from(originalKey, "https://original.example.test/a/b"),
        )
        assertTrue(owner.fingerprint.matches(Regex("^[a-f0-9]{64}$")))
    }

    @Test
    fun fingerprintsMatchTheFramedUtf8CrossPlatformVectors() {
        assertEquals(
            "82ceb1c04d3054205b81c7ba7e5e73811d182b2e5793e5bac5afda3590802629",
            CrumbQueueOwner.from("synthetic_write_key", "https://ingestion.example.invalid/base").fingerprint,
        )
        assertEquals(
            "c53bbbd95a08bd9a3e752264e981be5e9bd1c03e404b81841a89aa6e4a10fec9",
            CrumbQueueOwner.from("synthetic_key_☃", "https://ingestion.example.invalid/base").fingerprint,
        )
        assertEquals(
            "7ce7a235c1c39847d6b35e91ba5f90846ee4b4ef5ae4c59c488adbf876ff21b9",
            CrumbQueueOwner.from("synthetic_write_key", null).fingerprint,
        )
    }

    @Test
    fun configuredFactoryBindsAtCommitAndRejectsMissingStartBeforeWriting() {
        val parent = Files.createTempDirectory("crumb-owner-configured").toFile()
        val root = File(parent, "reports")
        Crumb.resetForTesting()
        try {
            val queue = CrumbReportQueue.configured(root)
            val original = fixture("rpt_ConfiguredOriginalAAAAAAAAAAAAA")
            assertThrows(IllegalStateException::class.java) {
                queue.enqueue(original.envelope, original.artifacts)
            }
            assertFalse("a rejected pre-start commit must not create queue files", root.exists())
            Crumb.start(CrumbConfiguration(
                originalKey,
                "synthetic",
                CrumbRelease("1", "1"),
                upload = CrumbUploadOptions(originalDestination),
            ))
            queue.enqueue(original.envelope, original.artifacts)
            queue.markUploading(original.envelope.reportId)
            assertEquals(
                CrumbQueueOwner.from(originalKey, originalDestination).fingerprint,
                metadata(root, original.envelope.reportId).getProperty("owner_fingerprint"),
            )
            val originalBytes = snapshot(root)
            Crumb.resetForTesting()
            val replacementKey = "synthetic-replacement-key"
            Crumb.start(CrumbConfiguration(
                replacementKey,
                "synthetic",
                CrumbRelease("1", "1"),
                upload = CrumbUploadOptions(originalDestination),
            ))
            queue.recoverInterruptedUploads()
            assertSnapshotEquals(originalBytes, snapshot(root))
            val replacement = fixture("rpt_ConfiguredReplacementAAAAAAAAAA")
            queue.enqueue(replacement.envelope, replacement.artifacts)
            val transport = AcceptingTransport()

            val result = CrumbReportUploadWorker(
                queue,
                CrumbUploadSettings(replacementKey, originalDestination),
                transport,
            ).runPass()

            assertEquals(1, result.uploadedReportCount)
            assertEquals(0, result.remainingReportCount)
            assertEquals(3, transport.requests.size)
            assertFalse(transport.requests.any {
                it.body?.toString(Charsets.UTF_8)?.contains(original.envelope.reportId) == true
            })
            assertSnapshotEquals(originalBytes, snapshot(root))
            assertEquals(CrumbQueuedReportState.UPLOADING, queue.reports().single().state)
            assertEquals(1, queue.reports().single().attemptCount)
        } finally {
            Crumb.resetForTesting()
            parent.deleteRecursively()
        }
    }

    private fun envelope(reportId: String): CrumbSerializedReportEnvelope = CrumbSerializedReportEnvelope(
        reportId,
        1_700_000_000_000,
        """{"schema_version":"1.0","report_id":"$reportId","artifacts":[]}""",
    )

    private fun fixture(reportId: String): Fixture {
        val bytes = "synthetic masked screenshot bytes".toByteArray()
        val byteSize = bytes.size
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val manifest = CrumbArtifactManifest(
            id = "art_0000000000000000",
            kind = "screenshot",
            mimeType = "image/png",
            byteSize = bytes.size.toLong(),
            sha256 = digest,
            redactionState = "masked",
            uploadId = "upl_0000000000000000",
        )
        return Fixture(
            CrumbSerializedReportEnvelope(
                reportId,
                1_700_000_000_000,
                """{"schema_version":"1.0","report_id":"$reportId","artifacts":[{"id":"art_0000000000000000","kind":"screenshot","mime_type":"image/png","byte_size":$byteSize,"sha256":"$digest","redaction_state":"masked","upload_id":"upl_0000000000000000"}]}""",
            ),
            listOf(CrumbQueueArtifact(manifest, bytes)),
        )
    }

    private fun metadata(root: File, reportId: String): Properties = Properties().apply {
        File(File(root, reportId), "record.properties").inputStream().use(::load)
    }

    private fun snapshot(root: File): Map<String, ByteArray> = root.walkTopDown()
        .filter(File::isFile)
        .associate { file -> file.relativeTo(root).path to file.readBytes() }

    private fun assertSnapshotEquals(expected: Map<String, ByteArray>, actual: Map<String, ByteArray>) {
        assertEquals(expected.keys, actual.keys)
        expected.forEach { (path, bytes) -> assertArrayEquals(path, bytes, actual.getValue(path)) }
    }

    private class AcceptingTransport : CrumbUploadTransport {
        val requests = mutableListOf<CrumbUploadHttpRequest>()

        override fun send(request: CrumbUploadHttpRequest): CrumbUploadHttpResponse {
            requests += request
            if (request.url.endsWith("/init")) {
                val envelope = JSONObject(String(requireNotNull(request.body), Charsets.UTF_8))
                    .getJSONObject("envelope")
                val reportId = envelope.getString("report_id")
                val manifests = envelope.getJSONArray("artifacts")
                val targets = org.json.JSONArray()
                for (index in 0 until manifests.length()) {
                    val manifest = manifests.getJSONObject(index)
                    targets.put(JSONObject()
                        .put("id", manifest.getString("id"))
                        .put("upload_id", manifest.getString("upload_id"))
                        .put("method", "PUT")
                        .put("url", "https://objects.example.test/synthetic")
                        .put("headers", JSONObject().put("content-type", "image/png")))
                }
                return CrumbUploadHttpResponse(
                    200,
                    JSONObject().put("report_id", reportId)
                        .put("status", "initialized").put("artifacts", targets).toString().toByteArray(),
                )
            }
            return CrumbUploadHttpResponse(200, """{"status":"accepted"}""".toByteArray())
        }
    }

    private data class Fixture(
        val envelope: CrumbSerializedReportEnvelope,
        val artifacts: List<CrumbQueueArtifact>,
    )
}
