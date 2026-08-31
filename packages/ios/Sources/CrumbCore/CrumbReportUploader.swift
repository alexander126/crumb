import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct CrumbUploadHTTPResponse: Sendable {
    package let statusCode: Int
    package let data: Data

    package init(statusCode: Int, data: Data = Data()) {
        self.statusCode = statusCode
        self.data = data
    }
}

package protocol CrumbUploadTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse
}

package struct CrumbURLSessionUploadTransport: CrumbUploadTransport {
    private let session: URLSession

    package init(session: URLSession = .shared) {
        self.session = session
    }

    package func send(_ request: URLRequest) async throws -> CrumbUploadHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard data.count <= 1_048_576,
              let response = response as? HTTPURLResponse else {
            throw CrumbUploadFailure(reason: "transport.invalid_response", retryable: true)
        }
        return CrumbUploadHTTPResponse(statusCode: response.statusCode, data: data)
    }
}

package struct CrumbUploadPassResult: Equatable, Sendable {
    package let uploadedReportCount: Int
    package let remainingReportCount: Int
    package let shouldRetry: Bool
    package let wasCancelled: Bool
}

/// Performs one bounded upload pass. Scheduling and connectivity live in CrumbUI.
package actor CrumbReportUploadWorker {
    private let queue: CrumbReportQueue
    private let settings: CrumbUploadSettings
    private let transport: any CrumbUploadTransport

    package init(
        queue: CrumbReportQueue = .shared,
        settings: CrumbUploadSettings,
        transport: any CrumbUploadTransport = CrumbURLSessionUploadTransport()
    ) {
        self.queue = queue
        self.settings = settings
        self.transport = transport
    }

    package func runPass() async -> CrumbUploadPassResult {
        var uploadedReportCount = 0
        var shouldRetry = false
        var wasCancelled = false

        do {
            try await queue.recoverInterruptedUploads()
            let reports = try await queue.reports()
            for report in reports {
                do {
                    try Task.checkCancellation()
                    try await queue.markUploading(reportID: report.reportID)
                    let payload = try await queue.load(reportID: report.reportID)
                    try await upload(payload)
                    try Task.checkCancellation()
                    try await queue.remove(reportID: report.reportID)
                    uploadedReportCount += 1
                } catch is CancellationError {
                    try? await queue.markPending(reportID: report.reportID)
                    wasCancelled = true
                    break
                } catch let failure as CrumbUploadFailure {
                    try? await queue.markFailed(reportID: report.reportID, reason: failure.reason)
                    if failure.retryable {
                        shouldRetry = true
                        break
                    }
                } catch {
                    try? await queue.markFailed(
                        reportID: report.reportID,
                        reason: "uploader.local_failure"
                    )
                }
            }
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            shouldRetry = true
        }

        let remainingReports = try? await queue.reports()
        return CrumbUploadPassResult(
            uploadedReportCount: uploadedReportCount,
            remainingReportCount: remainingReports?.count ?? 1,
            shouldRetry: shouldRetry,
            wasCancelled: wasCancelled
        )
    }

    private func upload(_ payload: CrumbQueuedReportPayload) async throws {
        let reportID = payload.summary.reportID
        let initResponse = try await sendLifecycle(
            path: ["sdk", "v1", "reports", "init"],
            reportID: reportID,
            operation: "init",
            body: wrappedEnvelope(payload.envelope)
        )
        let initialized = try decodeInitialization(initResponse.data, reportID: reportID)

        switch initialized.status {
        case "accepted":
            guard initialized.artifacts.isEmpty else {
                throw CrumbUploadFailure(reason: "init.invalid_response", retryable: false)
            }
        case "initialized":
            try validateTargets(initialized.artifacts, payload: payload)
            for artifact in payload.artifacts {
                try Task.checkCancellation()
                guard let target = initialized.artifacts.first(where: {
                    $0.id == artifact.manifest.id
                }) else {
                    throw CrumbUploadFailure(reason: "init.invalid_response", retryable: false)
                }
                try await put(artifact.data, target: target)
            }
        default:
            throw CrumbUploadFailure(reason: "init.terminal_state", retryable: false)
        }

        _ = try await sendLifecycle(
            path: ["sdk", "v1", "reports", reportID, "complete"],
            reportID: reportID,
            operation: "complete",
            body: nil
        )
    }

    private func sendLifecycle(
        path: [String],
        reportID: String,
        operation: String,
        body: Data?
    ) async throws -> CrumbUploadHTTPResponse {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(settings.projectKey)", forHTTPHeaderField: "Authorization")
        request.setValue("\(reportID):\(operation)", forHTTPHeaderField: "Idempotency-Key")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await send(request, operation: operation)
        guard (200..<300).contains(response.statusCode) else {
            throw httpFailure(operation: operation, statusCode: response.statusCode)
        }
        return response
    }

    private func put(_ data: Data, target: InitializationResponse.Artifact) async throws {
        guard target.method == "PUT",
              let url = URL(string: target.url),
              validUploadURL(url) else {
            throw CrumbUploadFailure(reason: "artifact.invalid_target", retryable: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.httpBody = data
        for (name, value) in target.headers where validHeaderName(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response = try await send(request, operation: "artifact")
        guard (200..<300).contains(response.statusCode) else {
            throw httpFailure(operation: "artifact", statusCode: response.statusCode)
        }
    }

    private func send(_ request: URLRequest, operation: String) async throws -> CrumbUploadHTTPResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as CrumbUploadFailure {
            throw failure
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CrumbUploadFailure(reason: "\(operation).network", retryable: true)
        }
    }

    private func validateTargets(
        _ targets: [InitializationResponse.Artifact],
        payload: CrumbQueuedReportPayload
    ) throws {
        let targetIDs = targets.map(\.id)
        guard targetIDs.count == Set(targetIDs).count,
              Set(targetIDs) == Set(payload.artifacts.map(\.manifest.id)) else {
            throw CrumbUploadFailure(reason: "init.invalid_response", retryable: false)
        }
        for target in targets {
            guard let artifact = payload.artifacts.first(where: { $0.manifest.id == target.id }),
                  target.uploadID == artifact.manifest.uploadID else {
                throw CrumbUploadFailure(reason: "init.invalid_response", retryable: false)
            }
        }
    }

    private func decodeInitialization(_ data: Data, reportID: String) throws -> InitializationResponse {
        do {
            let response = try JSONDecoder().decode(InitializationResponse.self, from: data)
            guard response.reportID == reportID else {
                throw CrumbUploadFailure(reason: "init.invalid_response", retryable: false)
            }
            return response
        } catch let failure as CrumbUploadFailure {
            throw failure
        } catch {
            throw CrumbUploadFailure(reason: "init.invalid_response", retryable: false)
        }
    }

    private func wrappedEnvelope(_ envelope: Data) -> Data {
        var body = Data("{\"envelope\":".utf8)
        body.append(envelope)
        body.append(Data("}".utf8))
        return body
    }

    private func endpoint(_ components: [String]) -> URL {
        components.reduce(settings.ingestionURL) { url, component in
            url.appendingPathComponent(component)
        }
    }

    private func validUploadURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        let baseScheme = settings.ingestionURL.scheme?.lowercased()
        return url.host != nil
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
            && (scheme == "https" || (scheme == "http" && baseScheme == "http"))
    }

    private func validHeaderName(_ value: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        )
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func httpFailure(operation: String, statusCode: Int) -> CrumbUploadFailure {
        let retryable = statusCode == 408 || statusCode == 425 || statusCode == 429
            || (500...599).contains(statusCode)
            || (operation == "artifact" && statusCode == 403)
        return CrumbUploadFailure(
            reason: "\(operation).http_\(statusCode)",
            retryable: retryable
        )
    }

    private struct InitializationResponse: Decodable, Sendable {
        let reportID: String
        let status: String
        let artifacts: [Artifact]

        enum CodingKeys: String, CodingKey {
            case reportID = "report_id"
            case status
            case artifacts
        }

        struct Artifact: Decodable, Sendable {
            let id: String
            let uploadID: String
            let method: String
            let url: String
            let headers: [String: String]

            enum CodingKeys: String, CodingKey {
                case id
                case uploadID = "upload_id"
                case method
                case url
                case headers
            }
        }
    }
}

private struct CrumbUploadFailure: Error, Sendable {
    let reason: String
    let retryable: Bool
}
