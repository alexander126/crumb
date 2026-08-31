package dev.crumb.ui

import dev.crumb.core.CrumbLogCaptureStatus
import dev.crumb.core.CrumbLogDiagnostic
import dev.crumb.core.CrumbLogEntry
import dev.crumb.core.CrumbLogOptions

internal object OnDemandLogCollector {
    fun capture(options: CrumbLogOptions): CrumbLogDiagnostic {
        if (!options.enabled) {
            return CrumbLogDiagnostic(
                status = CrumbLogCaptureStatus.DISABLED,
                sources = emptyList(),
                entries = emptyList(),
                truncated = false,
                droppedEntryCount = 0,
                failures = emptyList(),
            )
        }

        val provider = options.provider ?: return CrumbLogDiagnostic(
            status = CrumbLogCaptureStatus.UNAVAILABLE,
            sources = emptyList(),
            entries = emptyList(),
            truncated = false,
            droppedEntryCount = 0,
            failures = listOf("host_log_provider_not_configured"),
        )

        val supplied = runCatching { provider.recentLogs() }
        val entries = supplied.getOrElse { error ->
            return CrumbLogDiagnostic(
                status = CrumbLogCaptureStatus.UNAVAILABLE,
                sources = emptyList(),
                entries = emptyList(),
                truncated = false,
                droppedEntryCount = 0,
                failures = listOf("host_provider_failed:${error.javaClass.simpleName}"),
            )
        }
        val bounded = bound(entries, options)
        return CrumbLogDiagnostic(
            status = if (bounded.entries.isEmpty()) {
                CrumbLogCaptureStatus.EMPTY
            } else {
                CrumbLogCaptureStatus.CAPTURED
            },
            sources = listOf("host_provider"),
            entries = bounded.entries,
            truncated = bounded.dropped > 0,
            droppedEntryCount = bounded.dropped,
            failures = emptyList(),
        )
    }

    private fun bound(
        entries: List<CrumbLogEntry>,
        options: CrumbLogOptions,
    ): BoundedLogs {
        val capturedAt = System.currentTimeMillis()
        val earliest = capturedAt - options.lookbackMillis
        val candidates = entries
            .asSequence()
            .filter { it.timestampMillis in earliest..(capturedAt + 5_000) }
            .sortedByDescending(CrumbLogEntry::timestampMillis)
            .toList()
        val selected = mutableListOf<CrumbLogEntry>()
        var usedBytes = 0
        var dropped = 0

        candidates.forEach { entry ->
            if (selected.size >= options.maximumEntries) {
                dropped += 1
                return@forEach
            }
            val sanitized = entry.copy(
                source = LogSanitizer.sanitize(entry.source).ifBlank { "application" }.take(64),
                category = LogSanitizer.sanitize(entry.category).take(256),
                message = LogSanitizer.sanitize(entry.message).take(65_536),
            )
            val byteCount = sanitized.source.toByteArray().size +
                sanitized.category.toByteArray().size +
                sanitized.message.toByteArray().size + 32
            if (usedBytes + byteCount > options.maximumBytes) {
                dropped += 1
                return@forEach
            }
            selected += sanitized
            usedBytes += byteCount
        }

        return BoundedLogs(entries = selected.asReversed(), dropped = dropped)
    }

    private data class BoundedLogs(
        val entries: List<CrumbLogEntry>,
        val dropped: Int,
    )
}
