package dev.crumb.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.Path
import java.util.Properties

/**
 * Real queues on temporary roots with explicit owner fingerprints. Every
 * corruption is applied to committed bytes on disk, the way a damaged device
 * would present them. Mirrors the iOS suite of the same name.
 */
class CrumbQueueMetadataIsolationTest {
    /**
     * The defect this fixes: one damaged metadata record aborted the scan that
     * serves listing, recovery and admission, so healthy siblings became
     * invisible and new reports could not be committed.
     */
    @Test
    fun aDamagedRecordDoesNotHideItsHealthySiblings() = withRoot { root ->
        val queue = ownedQueue(root)
        queue.enqueue(envelope(healthyId), emptyList())
        queue.enqueue(envelope(damagedId), emptyList())
        damageMetadata(root, damagedId, malformedProperties)

        val restarted = ownedQueue(root)
        val listed = restarted.reports()
        restarted.recoverInterruptedUploads(owner)
        val owned = restarted.ownedReports(owner)
        val payload = restarted.load(healthyId)
        val admitted = restarted.enqueue(envelope(arrivingId), emptyList())

        assertEquals(listOf(healthyId), listed.map { it.reportId })
        assertEquals(listOf(healthyId), owned.map { it.reportId })
        assertEquals(healthyId, payload.summary.reportId)
        assertEquals(arrivingId, admitted.reportId)
    }

    @Test
    fun anUploadingSiblingRecoversExactlyOnceAcrossTwoRestarts() = withRoot { root ->
        val queue = ownedQueue(root)
        queue.enqueue(envelope(healthyId), emptyList())
        queue.enqueue(envelope(damagedId), emptyList())
        queue.markUploading(healthyId)
        damageMetadata(root, damagedId, malformedProperties)
        val damagedBytes = metadataFile(root, damagedId).readBytes()

        ownedQueue(root).recoverInterruptedUploads(owner)
        val afterFirst = ownedQueue(root).load(healthyId).summary
        ownedQueue(root).recoverInterruptedUploads(owner)
        val afterSecond = ownedQueue(root).load(healthyId).summary

        assertEquals(CrumbQueuedReportState.PENDING, afterFirst.state)
        assertEquals(CrumbQueuedReportState.PENDING, afterSecond.state)
        assertEquals(afterFirst.attemptCount, afterSecond.attemptCount)
        // The damaged entry is untouched: not repaired, not renamed, not deleted.
        assertArrayEquals(damagedBytes, metadataFile(root, damagedId).readBytes())
        assertTrue(File(root, damagedId).isDirectory)
    }

    @Test
    fun rejectedMetadataIsolatesOnlyItsOwnEntry() {
        val rejected = listOf(
            malformedProperties,
            "",
            "schema_version=2",
            "schema_version=2\nreport_id=rpt_SomethingElseAAAAAAAAAAAAAAA\nartifact_count=0",
            "schema_version=2\nreport_id=$damagedId\nartifact_count=0\nstate=TELEPORTING\n" +
                "submitted_at_millis=1\nattempt_count=0\ntotal_byte_size=1\n" +
                "envelope_byte_size=1\nenvelope_sha256=x",
            "schema_version=2\nreport_id=$damagedId\nartifact_count=0\nstate=PENDING\n" +
                "submitted_at_millis=1\nattempt_count=-1\ntotal_byte_size=1\n" +
                "envelope_byte_size=1\nenvelope_sha256=x",
        )
        rejected.forEach { metadata ->
            withRoot { root ->
                val queue = ownedQueue(root)
                queue.enqueue(envelope(healthyId), emptyList())
                queue.enqueue(envelope(damagedId), emptyList())
                damageMetadata(root, damagedId, metadata)

                val restarted = ownedQueue(root)

                assertEquals(
                    "metadata <$metadata> must isolate only its own entry",
                    listOf(healthyId),
                    restarted.reports().map { it.reportId },
                )
                // Direct load and same-ID admission stay strict about it.
                assertThrows(CrumbReportQueueException::class.java) { restarted.load(damagedId) }
                assertThrows(CrumbReportQueueException::class.java) {
                    restarted.enqueue(envelope(damagedId), emptyList())
                }
            }
        }
    }

    @Test
    fun positivelyMissingMetadataIsolatesWithoutForgettingTheDirectory() = withRoot { root ->
        val queue = ownedQueue(root)
        queue.enqueue(envelope(healthyId), emptyList())
        queue.enqueue(envelope(damagedId), emptyList())
        assertTrue(metadataFile(root, damagedId).delete())

        val restarted = ownedQueue(root)

        assertEquals(listOf(healthyId), restarted.reports().map { it.reportId })
        assertTrue(File(root, damagedId).isDirectory)
        // The ID stays reserved even though nothing can be read from it.
        assertThrows(CrumbReportQueueException::class.java) {
            restarted.enqueue(envelope(damagedId), emptyList())
        }
    }

    @Test
    fun anUnsupportedVersionFailsTheWholeOperation() {
        val futureVersions = listOf(
            "schema_version=3\nreport_id=$damagedId\nartifact_count=0\nstate=PENDING\n" +
                "submitted_at_millis=1\nattempt_count=0\ntotal_byte_size=1\n" +
                "envelope_byte_size=1\nenvelope_sha256=x",
            "schema_version=3\nsomething_new=true",
            "schema_version=99",
            "schema_version=0",
        )
        futureVersions.forEach { metadata ->
            withRoot { root ->
                val queue = ownedQueue(root)
                queue.enqueue(envelope(healthyId), emptyList())
                queue.enqueue(envelope(damagedId), emptyList())
                damageMetadata(root, damagedId, metadata)

                // Never skipped as ordinary corruption, and never adopted.
                assertThrows(
                    "metadata <$metadata> must fail the whole operation",
                    CrumbReportQueueException.CorruptQueue::class.java,
                ) { ownedQueue(root).reports() }
            }
        }
    }

    @Test
    fun aMetadataIoFailureIsRetryableRatherThanQuarantined() = withRoot { root ->
        val queue = ownedQueue(root)
        queue.enqueue(envelope(healthyId), emptyList())
        val metadata = metadataFile(root, healthyId)
        val saved = metadata.readBytes()
        // A directory where the metadata file belongs fails the read for every
        // uid, unlike a permission bit.
        assertTrue(metadata.delete())
        assertTrue(metadata.mkdir())

        assertThrows(CrumbReportQueueException.StorageFailure::class.java) {
            ownedQueue(root).reports()
        }

        // Restored I/O makes the original record usable again: it was never
        // quarantined.
        assertTrue(metadata.delete())
        metadata.writeBytes(saved)

        assertEquals(listOf(healthyId), ownedQueue(root).reports().map { it.reportId })
    }

    @Test
    fun admissionCountsOpaqueEntriesAgainstTheReportLimit() = withRoot { root ->
        val limits = CrumbQueueLimits(maximumReports = 2)
        val queue = CrumbReportQueue(root, owner, limits)
        queue.enqueue(envelope(healthyId), emptyList())
        queue.enqueue(envelope(damagedId), emptyList())
        damageMetadata(root, damagedId, malformedProperties)

        val restarted = CrumbReportQueue(root, owner, limits)

        // One record lists, but two directories are retained, so the queue is
        // full. Isolation must not hand out a slot the queue cannot honor.
        assertEquals(1, restarted.reports().size)
        assertThrows(CrumbReportQueueException.QueueFull::class.java) {
            restarted.enqueue(envelope(arrivingId), emptyList())
        }
    }

    /**
     * The discriminator between counting what metadata promises and counting
     * what is on disk: the metadata understates the payload and stays otherwise
     * valid, so the entry still lists.
     */
    @Test
    fun admissionCountsRetainedBytesRatherThanMetadataPromises() = withRoot { root ->
        val envelopeBytes = envelope(healthyId).json.toByteArray(Charsets.UTF_8).size.toLong()
        val limits = CrumbQueueLimits(
            maximumReports = 10,
            maximumTotalBytes = envelopeBytes + 8,
            maximumReportBytes = envelopeBytes,
        )
        CrumbReportQueue(root, owner, limits).enqueue(envelope(healthyId), emptyList())
        understatePayload(root, healthyId)

        val restarted = CrumbReportQueue(root, owner, limits)

        assertEquals(listOf(healthyId), restarted.reports().map { it.reportId })
        assertThrows(CrumbReportQueueException.QueueFull::class.java) {
            restarted.enqueue(envelope(arrivingId), emptyList())
        }
    }

    @Test
    fun anUnreferencedArtifactBlobStillCountsAsRetainedPayload() = withRoot { root ->
        val envelopeBytes = envelope(healthyId).json.toByteArray(Charsets.UTF_8).size.toLong()
        // Room for both reports but not for the stray blob, so the blob decides
        // the outcome: no metadata mentions it.
        val limits = CrumbQueueLimits(
            maximumReports = 10,
            maximumTotalBytes = 2 * envelopeBytes + 32,
            maximumReportBytes = envelopeBytes,
        )
        CrumbReportQueue(root, owner, limits).enqueue(envelope(healthyId), emptyList())
        val artifacts = File(File(root, healthyId), "artifacts").apply { mkdirs() }
        File(artifacts, "art_UnreferencedAAAA.bin").writeBytes(ByteArray(64) { 0x5A })

        assertThrows(CrumbReportQueueException.QueueFull::class.java) {
            CrumbReportQueue(root, owner, limits).enqueue(envelope(arrivingId), emptyList())
        }
    }

    @Test
    fun aSymlinkInAReportDirectoryFailsAdmissionClosed() = withRoot { root ->
        val queue = ownedQueue(root)
        queue.enqueue(envelope(healthyId), emptyList())
        val outside = File(root.parentFile, "outside-${root.name}").apply { mkdirs() }
        val target = File(outside, "target.bin").apply { writeBytes(ByteArray(32) { 0x5A }) }
        val artifacts = File(File(root, healthyId), "artifacts").apply { mkdirs() }
        try {
            Files.createSymbolicLink(
                File(artifacts, "art_LinkedAAAAAAAAA.bin").toPath(),
                target.toPath(),
            )

            assertThrows(CrumbReportQueueException.StorageFailure::class.java) {
                ownedQueue(root).enqueue(envelope(arrivingId), emptyList())
            }
            // Nothing outside the queue was read through, and nothing was removed.
            assertTrue(target.isFile)
        } finally {
            outside.deleteRecursively()
        }
    }

    @Test
    fun aCommittedDirectoryWithNoPayloadCountsZeroBytesAndKeepsItsSlot() = withRoot { root ->
        val limits = CrumbQueueLimits(maximumReports = 3)
        val queue = CrumbReportQueue(root, owner, limits)
        queue.enqueue(envelope(damagedId), emptyList())
        assertTrue(File(File(root, damagedId), "envelope.json").delete())
        damageMetadata(root, damagedId, malformedProperties)

        val restarted = CrumbReportQueue(root, owner, limits)
        // Zero payload bytes, so a new report of its own size still fits...
        val admitted = restarted.enqueue(envelope(arrivingId), emptyList())

        // ...while the directory still consumes a slot and reserves its ID.
        assertEquals(arrivingId, admitted.reportId)
        assertTrue(File(root, damagedId).isDirectory)
        assertThrows(CrumbReportQueueException::class.java) {
            restarted.enqueue(envelope(damagedId), emptyList())
        }
    }

    // MARK: - Fixtures

    private fun ownedQueue(root: File) = CrumbReportQueue(root, owner)

    private fun metadataFile(root: File, reportId: String) =
        File(File(root, reportId), "record.properties")

    private fun damageMetadata(root: File, reportId: String, metadata: String) {
        metadataFile(root, reportId).writeText(metadata)
    }

    /** Rewrites the record with a zero payload claim, valid in every other way. */
    private fun understatePayload(root: File, reportId: String) {
        val file = metadataFile(root, reportId)
        val properties = Properties().apply { file.inputStream().use(::load) }
        properties.setProperty("total_byte_size", "0")
        properties.setProperty("envelope_byte_size", "0")
        file.outputStream().use { properties.store(it, null) }
    }

    private fun envelope(reportId: String) = CrumbSerializedReportEnvelope(
        reportId,
        1_700_000_000_000,
        """{"schema_version":"1.0","report_id":"$reportId","artifacts":[]}""",
    )

    private fun withRoot(block: (File) -> Unit) {
        val root: Path = Files.createTempDirectory("crumb-isolation-")
        try {
            block(root.toFile())
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    private companion object {
        /** A malformed unicode escape: Properties.load rejects the bytes it read. */
        const val malformedProperties = "damaged=\\uZZZZ"
        const val healthyId = "rpt_HealthyAAAAAAAAAAAAAAAAAAAAAAAA"
        const val damagedId = "rpt_DamagedBBBBBBBBBBBBBBBBBBBBBBBB"
        const val arrivingId = "rpt_ArrivingCCCCCCCCCCCCCCCCCCCCCC"
        const val owner = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
}
