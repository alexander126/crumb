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
    /// Largest lifecycle response body the SDK will read. A larger response is
    /// abandoned while it is being received rather than buffered and discarded.
    package static let maximumResponseByteSize = 1_048_576

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

    /// Sends a request and reads at most `maximumByteSize` bytes of the
    /// response.
    ///
    /// A declared `Content-Length` above the ceiling is refused before the body
    /// is read, and reading otherwise stops the moment the ceiling would be
    /// exceeded, so an oversized body is never accumulated in host memory.
    package static func boundedData(
        for request: URLRequest,
        on session: URLSession = isolated,
        maximumByteSize: Int = maximumResponseByteSize
    ) async throws -> (Data, HTTPURLResponse) {
        let scoped = scoped(request)
        #if canImport(FoundationNetworking)
        return try await bufferedData(for: scoped, on: session, maximumByteSize: maximumByteSize)
        #else
        if #available(macOS 12.0, *) {
            return try await streamedData(
                for: scoped,
                on: session,
                maximumByteSize: maximumByteSize
            )
        }
        return try await bufferedData(for: scoped, on: session, maximumByteSize: maximumByteSize)
        #endif
    }

    #if !canImport(FoundationNetworking)
    @available(macOS 12.0, *)
    private static func streamedData(
        for request: URLRequest,
        on session: URLSession,
        maximumByteSize: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, urlResponse) = try await session.bytes(for: request)
        let response = try httpResponse(urlResponse, maximumByteSize: maximumByteSize)
        var data = Data()
        data.reserveCapacity(expectedCapacity(for: response, maximumByteSize: maximumByteSize))

        for try await byte in bytes {
            guard data.count < maximumByteSize else {
                throw CrumbHTTPSessionError.responseTooLarge
            }
            data.append(byte)
        }

        return (data, response)
    }
    #endif

    /// Fallback for platforms without incremental reading. The declared length
    /// is still refused before the body is requested.
    private static func bufferedData(
        for request: URLRequest,
        on session: URLSession,
        maximumByteSize: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, urlResponse) = try await session.data(for: request)
        let response = try httpResponse(urlResponse, maximumByteSize: maximumByteSize)
        guard data.count <= maximumByteSize else {
            throw CrumbHTTPSessionError.responseTooLarge
        }
        return (data, response)
    }

    private static func httpResponse(
        _ response: URLResponse,
        maximumByteSize: Int
    ) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw CrumbHTTPSessionError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(maximumByteSize) else {
            throw CrumbHTTPSessionError.responseTooLarge
        }
        return response
    }

    private static func expectedCapacity(
        for response: HTTPURLResponse,
        maximumByteSize: Int
    ) -> Int {
        let declared = response.expectedContentLength
        guard declared > 0 else { return 0 }
        return min(Int(declared), maximumByteSize)
    }
}

package enum CrumbHTTPSessionError: Error, Equatable {
    /// The response was not an HTTP response at all.
    case invalidResponse
    /// The response exceeded the caller's ceiling and was abandoned.
    case responseTooLarge
}
