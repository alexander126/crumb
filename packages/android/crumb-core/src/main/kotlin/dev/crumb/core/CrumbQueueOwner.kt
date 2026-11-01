package dev.crumb.core

import java.net.URI
import java.security.MessageDigest
import java.util.Locale

@ConsistentCopyVisibility
internal data class CrumbQueueOwner private constructor(val fingerprint: String) {
    companion object {
        fun from(projectKey: String, ingestionUrl: String?): CrumbQueueOwner {
            val destination = ingestionUrl?.let(::canonicalDestination) ?: "local-only"
            val keyBytes = projectKey.toByteArray(Charsets.UTF_8).size
            val destinationBytes = destination.toByteArray(Charsets.UTF_8).size
            val framed = "crumb.queue-owner.v1\n$keyBytes:$projectKey\n$destinationBytes:$destination"
            val fingerprint = MessageDigest.getInstance("SHA-256")
                .digest(framed.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            return CrumbQueueOwner(fingerprint)
        }

        private fun canonicalDestination(value: String): String {
            val uri = URI(value)
            val scheme = uri.scheme.lowercase(Locale.ROOT)
            val host = uri.host.lowercase(Locale.ROOT)
            val authorityHost = if (':' in host && !host.startsWith('[')) "[$host]" else host
            val defaultPort = if (scheme == "https") 443 else 80
            val port = if (uri.port == -1 || uri.port == defaultPort) "" else ":${uri.port}"
            // Match the uploader's effective base path without changing transport behavior.
            val path = uri.rawPath.orEmpty().trimEnd('/')
            return "$scheme://$authorityHost$port$path"
        }
    }
}
