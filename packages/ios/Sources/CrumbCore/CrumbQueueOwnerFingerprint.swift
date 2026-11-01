import CryptoKit
import Foundation

/// Identifies the exact credential and effective destination that own a local commit.
package enum CrumbQueueOwnerFingerprint {
    package static func make(projectKey: String, ingestionURL: URL?) -> String {
        let destination = canonicalDestination(ingestionURL)
        let framed = "crumb.queue-owner.v1\n\(projectKey.utf8.count):\(projectKey)"
            + "\n\(destination.utf8.count):\(destination)"
        return SHA256.hash(data: Data(framed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalDestination(_ url: URL?) -> String {
        guard let url else { return "local-only" }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port.flatMap { port -> String? in
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                return nil
            }
            return ":\(port)"
        } ?? ""
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        // Foundation consumes one separator when appending the lifecycle path, preserving extras.
        if path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }
}
