import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SDK-owned URL sessions.
///
/// The SDK never performs network work on `URLSession.shared`. The shared
/// session reads and writes `HTTPCookieStorage.shared` and the shared
/// `URLCache`, so a host cookie scoped to the configured ingestion host would
/// otherwise travel with SDK requests, and an ingestion response could mutate
/// the cookie jar the host application depends on. Report delivery must carry
/// only the report content the SDK owns.
package enum CrumbHTTPSession {
    /// Configuration for every SDK request: no cookie storage, no credential
    /// storage, and no response cache.
    package static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// The process-wide SDK session. Created once so report delivery and health
    /// probes reuse one connection pool without touching host storage.
    package static let isolated = URLSession(configuration: makeConfiguration())

    /// Removes host cookie participation from a request regardless of which
    /// session ends up sending it.
    package static func scoped(_ request: URLRequest) -> URLRequest {
        var scoped = request
        scoped.httpShouldHandleCookies = false
        return scoped
    }
}
