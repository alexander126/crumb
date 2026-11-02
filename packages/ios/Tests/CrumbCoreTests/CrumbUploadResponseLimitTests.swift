import Foundation
import Testing
@testable import CrumbCore

@Suite(.serialized)
struct CrumbUploadResponseLimitTests {
    private static let ceiling = 1_024

    /// Documents the behavior this fix replaces: `URLSession.data(for:)` returns
    /// only after the whole body is in memory, so a size guard placed after it
    /// runs after the allocation it is meant to prevent.
    @Test
    func bufferingTheWholeBodyFirstAllocatesEverythingTheEndpointSends() async throws {
        let plan = CrumbResponsePlan(
            declaredContentLength: 64 * Self.ceiling,
            chunkSize: Self.ceiling,
            chunkCount: 64,
            finishes: true
        )
        let session = plannedSession(plan)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await session.data(for: request(for: plan))

        #expect(data.count == 64 * Self.ceiling)
        #expect(plan.deliveredByteCount == 64 * Self.ceiling)
    }

    @Test
    func aDeclaredOversizeResponseIsRefusedBeforeItsBodyIsRead() async throws {
        let plan = CrumbResponsePlan(
            declaredContentLength: 64 * Self.ceiling,
            chunkSize: Self.ceiling,
            chunkCount: 0,
            finishes: false
        )

        let failure = await capturedFailure(plan)

        #expect(failure?.reason == "transport.response_too_large")
        #expect(failure?.retryable == false)
        #expect(plan.deliveredByteCount == 0)
    }

    @Test
    func anUndeclaredOversizeResponseStopsBeingReadAtTheCeiling() async throws {
        let chunkCount = 256
        let plan = CrumbResponsePlan(
            declaredContentLength: nil,
            chunkSize: Self.ceiling,
            chunkCount: chunkCount,
            finishes: true
        )
        let session = plannedSession(plan)
        let transport = CrumbURLSessionUploadTransport(
            session: session,
            maximumResponseByteSize: Self.ceiling
        )

        let failure = await captured(transport, plan)
        // Checked before the session is torn down, so cancellation is
        // attributable to the reader abandoning the body rather than to
        // invalidation.
        let wasCancelled = await plan.waitUntilCancelled()
        let delivered = plan.deliveredByteCount
        session.invalidateAndCancel()

        #expect(failure?.reason == "transport.response_too_large")
        #expect(failure?.retryable == false)
        // The ceiling was reached by reading, not from a declared length.
        #expect(delivered >= Self.ceiling)
        // The read was abandoned rather than completed. How many chunks the
        // endpoint had already pushed when the cancellation landed depends on
        // scheduling, so it is deliberately not asserted.
        #expect(wasCancelled)
        #expect(delivered < chunkCount * Self.ceiling)
    }

    @Test
    func aResponseAtTheCeilingIsStillDelivered() async throws {
        let plan = CrumbResponsePlan(
            declaredContentLength: Self.ceiling,
            chunkSize: Self.ceiling,
            chunkCount: 1,
            finishes: true
        )
        let session = plannedSession(plan)
        defer { session.invalidateAndCancel() }
        let transport = CrumbURLSessionUploadTransport(
            session: session,
            maximumResponseByteSize: Self.ceiling
        )

        let response = try await transport.send(request(for: plan))

        #expect(response.statusCode == 200)
        #expect(response.data.count == Self.ceiling)
    }

    @Test
    func aNonHTTPResponseKeepsItsRetryableClassification() async throws {
        let plan = CrumbResponsePlan(
            declaredContentLength: 0,
            chunkSize: 0,
            chunkCount: 0,
            finishes: true,
            respondWithHTTP: false
        )

        let failure = await capturedFailure(plan)

        #expect(failure?.reason == "transport.invalid_response")
        #expect(failure?.retryable == true)
    }

    /// The policy document fetch uses the same helper with its own, smaller
    /// ceiling, so the ceiling has to be a parameter rather than a constant.
    @Test
    func theSharedHelperHonorsTheCallersOwnCeiling() async throws {
        let plan = CrumbResponsePlan(
            declaredContentLength: 4 * Self.ceiling,
            chunkSize: Self.ceiling,
            chunkCount: 0,
            finishes: false
        )
        let session = plannedSession(plan)
        defer { session.invalidateAndCancel() }

        await #expect(throws: CrumbHTTPSessionError.responseTooLarge) {
            _ = try await CrumbHTTPSession.boundedData(
                for: request(for: plan),
                on: session,
                maximumByteSize: 2 * Self.ceiling
            )
        }
        #expect(plan.deliveredByteCount == 0)
    }

    private func request(for plan: CrumbResponsePlan) -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://ingestion.crumb.test/sdk/v1/reports/init")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue(plan.id, forHTTPHeaderField: CrumbResponsePlan.headerField)
        return request
    }

    private func plannedSession(_ plan: CrumbResponsePlan) -> URLSession {
        CrumbResponsePlan.register(plan)
        let configuration = CrumbHTTPSession.makeConfiguration()
        configuration.protocolClasses = [CrumbPlannedResponseURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    private func capturedFailure(_ plan: CrumbResponsePlan) async -> CrumbUploadFailure? {
        let session = plannedSession(plan)
        defer { session.invalidateAndCancel() }
        let transport = CrumbURLSessionUploadTransport(
            session: session,
            maximumResponseByteSize: Self.ceiling
        )
        return await captured(transport, plan)
    }

    private func captured(
        _ transport: CrumbURLSessionUploadTransport,
        _ plan: CrumbResponsePlan
    ) async -> CrumbUploadFailure? {
        do {
            _ = try await transport.send(request(for: plan))
            return nil
        } catch let failure as CrumbUploadFailure {
            return failure
        } catch {
            return nil
        }
    }
}

/// One planned response, owned by the test that created it. The protocol finds
/// it by the id carried on the request, so parallel tests never share state.
final class CrumbResponsePlan: @unchecked Sendable {
    static let headerField = "X-Crumb-Test-Plan"

    let id = UUID().uuidString
    let declaredContentLength: Int?
    let chunkSize: Int
    let chunkCount: Int
    /// Whether the planned response ever completes. A plan that is refused from
    /// its headers alone never needs to offer a body.
    let finishes: Bool
    let respondWithHTTP: Bool

    private let lock = NSLock()
    private var delivered = 0
    private var cancelled = false

    init(
        declaredContentLength: Int?,
        chunkSize: Int,
        chunkCount: Int,
        finishes: Bool,
        respondWithHTTP: Bool = true
    ) {
        self.declaredContentLength = declaredContentLength
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
        self.finishes = finishes
        self.respondWithHTTP = respondWithHTTP
    }

    var deliveredByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func recordDelivery(_ byteCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        delivered += byteCount
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    /// Waits, bounded, for the loader to cancel the request. The protocol stops
    /// delivering as soon as it observes this, so a test can assert on the
    /// abandonment without racing the delivery loop.
    func waitUntilCancelled(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return isCancelled
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: CrumbResponsePlan] = [:]

    static func register(_ plan: CrumbResponsePlan) {
        registryLock.lock()
        defer { registryLock.unlock() }
        registry[plan.id] = plan
    }

    static func plan(for request: URLRequest) -> CrumbResponsePlan? {
        guard let id = request.value(forHTTPHeaderField: headerField) else { return nil }
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[id]
    }
}

/// Answers with the request's planned response. The delivered byte count is the
/// evidence of how much of the body the reader actually pulled.
final class CrumbPlannedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        CrumbResponsePlan.plan(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let plan = CrumbResponsePlan.plan(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        guard plan.respondWithHTTP else {
            client?.urlProtocol(
                self,
                didReceive: URLResponse(
                    url: url,
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var headers = ["Content-Type": "application/json"]
        if let declared = plan.declaredContentLength {
            headers["Content-Length"] = String(declared)
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Delivered off the loading thread: while startLoading is executing,
        // the loader cannot call stopLoading, so a synchronous loop would push
        // the whole body no matter when the reader gave up — and the test could
        // not tell an abandoned transfer from a completed one.
        let chunk = Data(repeating: 0x7A, count: plan.chunkSize)
        Self.deliveryQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<plan.chunkCount {
                if plan.isCancelled { return }
                self.client?.urlProtocol(self, didLoad: chunk)
                plan.recordDelivery(chunk.count)
                usleep(1_000)
            }
            if plan.finishes {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private static let deliveryQueue = DispatchQueue(label: "crumb.test.planned-response")

    override func stopLoading() {
        CrumbResponsePlan.plan(for: request)?.cancel()
    }
}
