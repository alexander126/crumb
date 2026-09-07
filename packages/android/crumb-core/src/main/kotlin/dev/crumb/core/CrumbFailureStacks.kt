package dev.crumb.core

import org.json.JSONArray
import org.json.JSONObject

/** Bounded managed frames. This never installs a handler or claims C/C++ coverage. */
internal object CrumbFailureStacks {
    private const val maximumBytes = 12_288

    fun capture(): CrumbStackTraceDiagnostic? = runCatching {
        val current = Thread.currentThread()
        val stacks = Thread.getAllStackTraces().entries.sortedWith { left, right ->
            val leftRank = if (left.key === current) 0 else if (left.key.name == "main") 1 else 2
            val rightRank = if (right.key === current) 0 else if (right.key.name == "main") 1 else 2
            val rank = leftRank.compareTo(rightRank)
            if (rank != 0) rank else left.key.id.compareTo(right.key.id)
        }
        var truncated = stacks.size > 32
        val threads = mutableListOf<CrumbThreadStackDiagnostic>()
        for ((thread, frames) in stacks.take(32)) {
            if (frames.isEmpty()) continue
            if (frames.size > 16) truncated = true
            threads.add(CrumbThreadStackDiagnostic(thread.id, safe(thread.name, 128), thread.state.name.lowercase(),
                frames.take(16).map { safe(it.toString(), 512) }))
            while (encode(diagnostic(threads, true)).toString().toByteArray().size > maximumBytes) {
                truncated = true
                val last = threads.removeAt(threads.lastIndex)
                if (last.frames.size <= 1) break
                threads.add(last.copy(frames = last.frames.dropLast(1)))
            }
            if (threads.lastOrNull()?.id != thread.id) break
        }
        diagnostic(threads, truncated)
    }.getOrNull()

    private fun diagnostic(threads: List<CrumbThreadStackDiagnostic>, truncated: Boolean) = CrumbStackTraceDiagnostic(
        if (threads.isEmpty()) CrumbStackTraceCaptureStatus.UNAVAILABLE else CrumbStackTraceCaptureStatus.CAPTURED,
        "managed_threads", threads.toList(), truncated, if (threads.isEmpty()) "managed_stack_capture_empty" else null,
    )

    fun encode(value: CrumbStackTraceDiagnostic): JSONObject = JSONObject().apply {
        put("truncated", value.truncated)
        put("threads", JSONArray().apply {
            value.threads.forEach { thread -> put(JSONObject().apply {
                put("id", thread.id); put("name", thread.name); put("state", thread.state)
                put("frames", JSONArray(thread.frames))
            }) }
        })
    }

    fun decode(value: JSONObject?): CrumbStackTraceDiagnostic? = runCatching {
        require(value != null && value.toString().toByteArray().size <= maximumBytes)
        val threads = value.getJSONArray("threads")
        require(threads.length() <= 32)
        diagnostic((0 until threads.length()).map { index ->
            val thread = threads.getJSONObject(index)
            val frames = thread.getJSONArray("frames")
            require(frames.length() <= 16)
            val name = thread.getString("name")
            val state = thread.getString("state")
            require(name.toByteArray().size <= 128 && state.toByteArray().size <= 64)
            CrumbThreadStackDiagnostic(thread.getLong("id"), safe(name, 128), state,
                (0 until frames.length()).map {
                    val frame = frames.getString(it)
                    require(frame.toByteArray().size <= 512)
                    safe(frame, 512)
                })
        }, value.getBoolean("truncated"))
    }.getOrNull()

    private fun safe(value: String, bytes: Int): String {
        val sanitized = CrumbFailureText.sanitize(value)
        // Unicode scalar-safe bounds without leaving a broken UTF-8 sequence.
        var end = minOf(sanitized.length, bytes)
        while (sanitized.substring(0, end).toByteArray().size > bytes) end--
        if (end > 0 && sanitized[end - 1].isHighSurrogate()) end--
        return sanitized.substring(0, end)
    }
}
