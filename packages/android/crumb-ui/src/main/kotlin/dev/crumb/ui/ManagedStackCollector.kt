package dev.crumb.ui

import dev.crumb.core.CrumbStackTraceCaptureStatus
import dev.crumb.core.CrumbStackTraceDiagnostic
import dev.crumb.core.CrumbThreadStackDiagnostic

internal object ManagedStackCollector {
    private const val maximumThreads = 50
    private const val maximumFramesPerThread = 40

    fun capture(): CrumbStackTraceDiagnostic {
        val allStacks = runCatching { Thread.getAllStackTraces() }.getOrElse { error ->
            return CrumbStackTraceDiagnostic(
                status = CrumbStackTraceCaptureStatus.UNAVAILABLE,
                scope = "managed_threads",
                threads = emptyList(),
                truncated = false,
                unavailableReason = "managed_thread_stacks_failed:${error.javaClass.simpleName}",
            )
        }
        val sorted = allStacks.entries.sortedWith(
            compareByDescending<Map.Entry<Thread, Array<StackTraceElement>>> {
                it.key.name == "main"
            }.thenBy { it.key.name },
        )
        @Suppress("DEPRECATION")
        val threads = sorted.take(maximumThreads).map { (thread, frames) ->
            CrumbThreadStackDiagnostic(
                id = thread.id,
                name = thread.name.ifBlank { "thread-${thread.id}" }.take(256),
                state = thread.state.name.lowercase(),
                frames = frames.take(maximumFramesPerThread).map { it.toString().take(2_048) },
            )
        }

        return CrumbStackTraceDiagnostic(
            status = CrumbStackTraceCaptureStatus.CAPTURED,
            scope = "managed_threads",
            threads = threads,
            truncated = sorted.size > maximumThreads ||
                sorted.any { it.value.size > maximumFramesPerThread },
            unavailableReason = null,
        )
    }
}
