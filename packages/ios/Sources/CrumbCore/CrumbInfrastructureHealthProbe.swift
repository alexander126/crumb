import Foundation

package struct CrumbHealthHeadResult: Sendable {
    package let statusCode: Int?
    package let latencyMilliseconds: Int
    package let failure: String?

    package init(statusCode: Int?, latencyMilliseconds: Int, failure: String?) {
        self.statusCode = statusCode
        self.latencyMilliseconds = latencyMilliseconds
        self.failure = failure
    }
}

package enum CrumbInfrastructureHealthProbe {
    package typealias HeadRequest = (URLRequest, TimeInterval) -> CrumbHealthHeadResult

    package static func capture(
        url: URL,
        timeout: TimeInterval,
        head: HeadRequest = performHead
    ) -> CrumbHealthCheckDiagnostic {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "HEAD"
        let result = head(request, timeout)
        return CrumbHealthCheckDiagnostic(
            host: url.host ?? "unknown",
            succeeded: result.failure == nil &&
                (result.statusCode.map { (200..<300).contains($0) } ?? false),
            statusCode: result.statusCode,
            latencyMilliseconds: min(max(result.latencyMilliseconds, 0), 30_000),
            failure: result.failure.map { String($0.prefix(128)) }
        )
    }

    private static func performHead(
        request: URLRequest,
        timeout: TimeInterval
    ) -> CrumbHealthHeadResult {
        let startedAt = DispatchTime.now()
        let result = HealthProbeValue()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            result.setIfEmpty(
                CrumbHealthHeadResult(
                    statusCode: (response as? HTTPURLResponse)?.statusCode,
                    latencyMilliseconds: elapsedMilliseconds(since: startedAt),
                    failure: error.map(failureName)
                )
            )
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return CrumbHealthHeadResult(
                statusCode: nil,
                latencyMilliseconds: Int(timeout * 1_000),
                failure: "timeout"
            )
        }
        return result.value ?? CrumbHealthHeadResult(
            statusCode: nil,
            latencyMilliseconds: elapsedMilliseconds(since: startedAt),
            failure: "unavailable"
        )
    }
}

private func elapsedMilliseconds(since start: DispatchTime) -> Int {
    let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return Int(elapsed / 1_000_000)
}

private func failureName(_ error: Error) -> String {
    guard let error = error as? URLError else {
        return String(String(describing: type(of: error)).prefix(128))
    }
    return switch error.code {
    case .timedOut: "timeout"
    case .notConnectedToInternet: "not_connected"
    case .cannotFindHost, .dnsLookupFailed: "cannot_find_host"
    case .cannotConnectToHost: "cannot_connect"
    case .networkConnectionLost: "connection_lost"
    case .secureConnectionFailed, .serverCertificateUntrusted: "tls_failed"
    case .cancelled: "cancelled"
    default: "transport_error"
    }
}

private final class HealthProbeValue: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CrumbHealthHeadResult?

    var value: CrumbHealthHeadResult? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func setIfEmpty(_ value: CrumbHealthHeadResult) {
        lock.lock()
        defer { lock.unlock() }
        if storage == nil { storage = value }
    }
}
