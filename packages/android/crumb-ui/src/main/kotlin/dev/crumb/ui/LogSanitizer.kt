package dev.crumb.ui

internal object LogSanitizer {
    private const val credentialKeys =
        """(?:proxy[-_]?authorization|authorization|(?:set[-_]?)?cookie|password|passwd|secret|(?:access|refresh|id|auth|session)[_-]?token|token|client[_-]?secret|(?:x[_-]?)?api[_-]?key)"""
    private const val credentialPrefix =
        """(?i)(?<![A-Za-z0-9_-])((["']?)$credentialKeys\2\s*+[:=]\s*+)"""
    private const val headerPrefix =
        """(?i)(?<![A-Za-z0-9_-])((["']?)(?:proxy[-_]?authorization|authorization|(?:set[-_]?)?cookie)\2\s*+[:=]\s*+)"""

    private val replacements = listOf(
        Regex(credentialPrefix + """"(?:\\[^\r\n]|[^"\\\r\n])*+(?:"|\\?(?=[\r\n]|$))""") to
            "$1\"[REDACTED]\"",
        Regex(credentialPrefix + """'(?:\\[^\r\n]|[^'\\\r\n])*+(?:'|\\?(?=[\r\n]|$))""") to
            "$1'[REDACTED]'",
        // Unknown structured credential values fail closed, including truncated or multiline values.
        Regex(credentialPrefix + """(?!\[REDACTED\](?=[\s,;}\]]|$))[\[{][\s\S]*""") to "$1[REDACTED]",
        // Consume all header segments and folded continuations before flattening line endings.
        Regex(headerPrefix + """(?!["']|\[REDACTED\](?=[\s,;}\]]|$))[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*""") to
            "$1[REDACTED]",
        Regex(credentialPrefix + """(?!["']|\[REDACTED\](?=[\s,;}\]]|$))[^\s,;}\]]+""") to "$1[REDACTED]",
        Regex("(?i)(https?://)[^/\\s:@]+:[^/@\\s]+@") to "$1[REDACTED]@",
        Regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+") to "Bearer [REDACTED]",
        Regex("(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b") to "[REDACTED_EMAIL]",
        Regex("\\b(?:\\d[ -]*?){13,19}\\b") to "[REDACTED_NUMBER]",
        Regex("([?&][A-Za-z0-9._~-]+)=([^&#\\s]*)") to "$1=[REDACTED]",
        Regex("[\\u0000-\\u001F\\u007F]") to " ",
    )

    fun sanitize(value: String): String = replacements.fold(value) { result, (pattern, replacement) ->
        result.replace(pattern, replacement)
    }
}
