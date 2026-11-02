import Foundation
import Testing
@testable import CrumbCore

struct CrumbHTTPSessionTests {
    /// Documents the storage the shared session exposes. The SDK must not use
    /// it: its cookie jar and response cache belong to the host application.
    @Test
    func theSharedSessionIsBackedByHostStorage() {
        #expect(URLSession.shared.configuration.httpCookieStorage === HTTPCookieStorage.shared)
        #expect(URLSession.shared.configuration.httpShouldSetCookies)
    }

    @Test
    func theSDKSessionOwnsNoHostStorage() {
        let configuration = CrumbHTTPSession.isolated.configuration

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func scopingARequestDisablesCookieHandling() throws {
        let url = try #require(URL(string: "https://ingestion.crumb.test/sdk/v1/reports/init"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        #expect(request.httpShouldHandleCookies)

        let scoped = CrumbHTTPSession.scoped(request)

        #expect(scoped.httpShouldHandleCookies == false)
        #expect(scoped.url == url)
        #expect(scoped.httpMethod == "POST")
        #expect(scoped.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func theUploadTransportSendsRequestsThatRefuseHostCookies() async throws {
        let url = try #require(URL(string: "https://ingestion.crumb.test/sdk/v1/reports/init"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        CrumbRecordingURLProtocol.reset()
        let configuration = CrumbHTTPSession.makeConfiguration()
        configuration.protocolClasses = [CrumbRecordingURLProtocol.self]
        let transport = CrumbURLSessionUploadTransport(
            session: URLSession(configuration: configuration)
        )

        let response = try await transport.send(request)
        let recorded = try #require(CrumbRecordingURLProtocol.lastRequest)

        #expect(response.statusCode == 200)
        #expect(recorded.httpShouldHandleCookies == false)
        #expect(recorded.value(forHTTPHeaderField: "Cookie") == nil)
    }
}

/// Captures the request a session hands to the protocol layer and answers with
/// a fixed response so no test performs real network work.
final class CrumbRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: URLRequest?

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        recorded = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded = request
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Set-Cookie": "session=host-value; Path=/"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
