package dev.crumb.core

internal object CrumbFailureText {
    fun sanitize(value: String, preserveNewlines: Boolean = false): String {
        var sanitized = value
        REDACTIONS.forEach { (pattern, replacement) -> sanitized = pattern.replace(sanitized, replacement) }
        return sanitized.map { character ->
            if (character == '\n' && preserveNewlines) character
            else if (character == '\t' && preserveNewlines) character
            else if (character.isISOControl()) ' ' else character
        }.joinToString("")
    }

    val REDACTIONS = listOf(
        Regex("(?i)(https?://)[^/\\s:@]+:[^/@\\s]+@") to "$1[REDACTED]@",
        Regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+") to "Bearer [REDACTED]",
        Regex(
            "(?i)\\b(authorization|cookie|set-cookie|password|passwd|secret|token|api[_-]?key)" +
                "\\s*[:=]\\s*(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
        ) to "$1=[REDACTED]",
        Regex("(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b") to "[REDACTED_EMAIL]",
        Regex("\\b(?:\\d[ -]*?){13,19}\\b") to "[REDACTED_NUMBER]",
        Regex("([?&][A-Za-z0-9._~-]+)=([^&#\\s]*)") to "$1=[REDACTED]",
    )
}
