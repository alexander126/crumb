package dev.crumb.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CrumbQueueCleanupLinkTest {
    /**
     * The defect this fixes: cleanup used Kotlin's File.deleteRecursively(),
     * which walks with FileTreeWalk and follows symbolic links to directories.
     * A link planted in a tombstone tree therefore deleted the contents of the
     * link's target, outside the queue root.
     */
    @Test
    fun tombstoneCleanupDoesNotFollowALinkOutOfTheQueue() {
        withQueue { root, outside ->
            val tombstone = File(root, ".delete-rpt_SyntheticAAAAAAAAAAAAAAAAAAAAAAA-0001")
            assertTrue(tombstone.mkdirs())
            Files.createSymbolicLink(File(tombstone, "escape").toPath(), outside.toPath())

            queue(root).reports()

            assertTrue("bytes outside the queue must survive", File(outside, "keep.txt").isFile)
            assertFalse("the tombstone must still be cleaned up", tombstone.exists())
        }
    }

    @Test
    fun stagingCleanupDoesNotFollowALinkOutOfTheQueue() {
        withQueue { root, outside ->
            val staging = File(root, ".tmp-00000000-0000-0000-0000-000000000000")
            assertTrue(staging.mkdirs())
            Files.createSymbolicLink(File(staging, "escape").toPath(), outside.toPath())

            queue(root).reports()

            assertTrue(File(outside, "keep.txt").isFile)
            assertFalse(staging.exists())
        }
    }

    @Test
    fun cleanupStillRemovesOrdinaryFilesAndNestedDirectories() {
        withQueue { root, _ ->
            val tombstone = File(root, ".delete-rpt_SyntheticAAAAAAAAAAAAAAAAAAAAAAA-0002")
            val nested = File(tombstone, "artifacts/deeper")
            assertTrue(nested.mkdirs())
            File(tombstone, "record.properties").writeText("synthetic")
            File(nested, "artifact.bin").writeBytes(byteArrayOf(1, 2, 3))

            queue(root).reports()

            assertFalse(tombstone.exists())
        }
    }

    @Test
    fun aLinkedFileIsUnlinkedWithoutDeletingItsTarget() {
        withQueue { root, outside ->
            val target = File(outside, "keep.txt")
            val tombstone = File(root, ".delete-rpt_SyntheticAAAAAAAAAAAAAAAAAAAAAAA-0003")
            assertTrue(tombstone.mkdirs())
            val link = File(tombstone, "linked-file")
            Files.createSymbolicLink(link.toPath(), target.toPath())

            queue(root).reports()

            assertTrue(target.isFile)
            assertFalse(Files.exists(link.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS))
        }
    }

    /** Cleanup is best effort: a surviving entry must not fail the operation. */
    @Test
    fun healthyReportsStillListWhenAStagingEntryCannotBeRemoved() {
        withQueue { root, _ ->
            val staging = File(root, ".tmp-11111111-1111-1111-1111-111111111111")
            assertTrue(staging.mkdirs())
            File(staging, "partial.bin").writeBytes(byteArrayOf(9))

            val reports = queue(root).reports()

            assertTrue(reports.isEmpty())
        }
    }

    private fun queue(root: File) =
        CrumbReportQueue(root, CrumbQueueOwnerFingerprint.from(projectKey, destination))

    private fun withQueue(block: (root: File, outside: File) -> Unit) {
        val base = Files.createTempDirectory("crumb-cleanup-link-").toFile()
        val root = File(base, "queue").apply { mkdirs() }
        val outside = File(base, "outside").apply { mkdirs() }
        File(outside, "keep.txt").writeText("synthetic bytes outside the queue")
        try {
            block(root, outside)
        } finally {
            base.deleteRecursively()
        }
    }

    private companion object {
        const val projectKey = "synthetic_cleanup_write_key"
        const val destination = "https://cleanup.example.invalid"
    }
}
