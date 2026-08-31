package dev.crumb.ui

internal object LogSanitizer {
    private val replacements = listOf(
        Regex("(?i)(https?://)[^/\\s:@]+:[^/@\\s]+@") to "$1[REDACTED]@",
        Regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+") to "Bearer [REDACTED]",
        Regex(
            "(?i)\\b(authorization|cookie|set-cookie|password|passwd|secret|token|api[_-]?key)" +
                "\\s*[:=]\\s*(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
        ) to "$1=[REDACTED]",
        Regex("(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b") to "[REDACTED_EMAIL]",
        Regex("\\b(?:\\d[ -]*?){13,19}\\b") to "[REDACTED_NUMBER]",
        Regex("([?&][A-Za-z0-9._~-]+)=([^&#\\s]*)") to "$1=[REDACTED]",
        Regex("[\\u0000-\\u001F\\u007F]") to " ",
    )

    fun sanitize(value: String): String = replacements.fold(value) { result, (pattern, replacement) ->
        result.replace(pattern, replacement)
    }
}
